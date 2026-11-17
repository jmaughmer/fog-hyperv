# frozen_string_literal: true

require 'test_helper'

# The cluster read path had never run under Fog.mock!: Get-Cluster has no Mock of
# its own, so it is served by Fog::Hyperv::Compute::Mock#method_missing, which
# answers any registered request that has a mock_files/<name>.json. Writing these
# tests found three things that did not work — the mocked-request path itself,
# Cluster#reload, and the absence of any id or name filtering — and this is the file
# that keeps all of them fixed.
class UnitClusterTest < Minitest::Test
  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
  end

  def teardown
    Fog.unmock!
  end

  def test_lists_the_clusters_the_host_reports
    cluster = @client.clusters.first

    assert_equal 'mock-cluster', cluster.name
    assert_equal 'example.com', cluster.domain
    assert_equal 'becc0c8a-6444-4df5-bcd8-585ebab46518', cluster.id
  end

  def test_gets_a_cluster_by_name
    assert_equal 'mock-cluster', @client.clusters.get('mock-cluster').name
  end

  # Clusters#get tells a GUID from a name and asks for it as _by_id, which the real
  # request filters on the host itself
  def test_gets_a_cluster_by_id
    assert_equal 'mock-cluster', @client.clusters.get('becc0c8a-6444-4df5-bcd8-585ebab46518').name
  end

  # Filtering only matters when it can say no, and the answer has to be the one
  # fog's contract gives: an empty reply used to reach new as nil, which merged into
  # the creation attributes as a TypeError, so a miss looked like a transport
  # failure. foreman_hyperv's destroy_vm rescues Fog::Errors::NotFound as "it is
  # gone", which is the case that never arrived.
  def test_a_cluster_that_does_not_exist_is_not_found
    assert_raises(Fog::Errors::NotFound) { @client.clusters.get('no-such-cluster') }
    assert_raises(Fog::Errors::NotFound) { @client.clusters.get('00000000-0000-0000-0000-000000000000') }
  end

  # Cluster#hosts goes through Get-ClusterNode and then resolves every node name it
  # gets back as a host, which is why it is worth a test of its own: the cluster
  # model is only useful to Foreman if the nodes come out as Host models, and there
  # has to be more than one of them to prove it maps rather than picks.
  def test_maps_cluster_nodes_onto_hosts
    hosts = @client.clusters.first.hosts

    assert_equal 2, hosts.count
    assert(hosts.all? { |h| h.is_a? Fog::Hyperv::Compute::Host })
    assert_equal ['MOCK-HOST', 'MOCK-NODE2'], hosts.map(&:name)
  end

  # Cluster#reload asks for the cluster by id and only the model's own fields. It
  # used to read data.attributes off what Get-Cluster returns, which is a Hash (or
  # an array), not a model, so the call could not have worked against a real host
  # either
  def test_reloads_a_cluster
    cluster = @client.clusters.first

    assert_equal 'mock-cluster', cluster.reload.name
    assert_equal 'becc0c8a-6444-4df5-bcd8-585ebab46518', cluster.reload.id
  end

  # The Cluster Shared Volumes are what a placement decision picks from, so the path
  # from the fixture to a model with its volume path has to hold.
  def test_lists_the_cluster_shared_volumes
    volumes = @client.clusters.first.shared_volumes

    assert_equal ['Cluster Volume1', 'Cluster Volume2'], volumes.map(&:name)
    assert(volumes.all? { |v| v.is_a? Fog::Hyperv::Compute::ClusterSharedVolume })
    assert_equal 'C:\\ClusterStorage\\Volume1', volumes.first.volume_path
    assert_equal 'mock-node2', volumes.last.owner_node
    assert_equal 1_073_741_824_000, volumes.first.shared_volume[:size]
  end

  def test_a_shared_volume_can_be_asked_for_by_name
    assert_equal 'Cluster Volume2', @client.cluster_shared_volumes.get('Cluster Volume2').name
    assert_raises(Fog::Errors::NotFound) { @client.cluster_shared_volumes.get('Cluster Volume3') }
  end

  # The role list is how the plugin finds which node owns a machine, so it has to
  # carry the owner per role and name the machine the way Hyper-V names the role.
  def test_lists_the_clustered_virtual_machines_and_their_owners
    roles = @client.clusters.first.roles

    assert_equal ['Virtual Machine mockvm1', 'Virtual Machine mockvm2'], roles.map(&:name)
    assert_equal ['mockvm1', 'mockvm2'], roles.map(&:vm_name)
    assert_equal ['mock-host', 'mock-node2'], roles.map(&:owner_node)
    assert(roles.all? { |r| r.is_a? Fog::Hyperv::Compute::ClusterVirtualMachineRole })
    assert_equal 500, roles.last.priority
  end

  def test_a_role_can_be_asked_for_by_the_machines_name
    role = @client.cluster_virtual_machine_roles.get('Virtual Machine mockvm2')

    assert_equal 'mock-node2', role.owner_node
    assert_raises(Fog::Errors::NotFound) do
      @client.cluster_virtual_machine_roles.get('Virtual Machine mockvm3')
    end
  end

  # The plugin holds a machine's GUID and needs the node it runs on, so the id filter
  # is the lookup that matters. It reads through a ClusterGroup field a real cluster
  # is reported to carry without documenting it, which is why the fixture says so too.
  def test_a_role_can_be_asked_for_by_the_machines_id
    role = @client.clusters.first.roles.detect do |r|
      r.virtual_machine_id == '20ff7fe3-fd54-425c-aa97-fbf3c2e7a868'
    end

    assert_equal 'mock-node2', role&.owner_node

    by_id = @client.get_cluster_virtual_machine_role(vm_id: '416E49FD-28DD-413C-9743-AA3E69E4807D')

    assert_equal ['Virtual Machine mockvm1'], [by_id].flatten.map { |r| r[:name] }
    assert_empty @client.get_cluster_virtual_machine_role(vm_id: '00000000-0000-0000-0000-000000000000')
  end

  # Making a machine highly available, and taking that away again, are the two calls
  # the plugin's create and destroy paths are built around: they take the machine by
  # id and run against the node that owns it.
  def test_a_machine_can_be_made_highly_available_and_taken_back_out
    assert_equal true, @client.add_cluster_virtual_machine_role(id: '416e49fd-28dd-413c-9743-aa3e69e4807d',
                                                                computer_name: 'MOCK-HOST')
    assert_equal true, @client.remove_cluster_virtual_machine_role(id: '416e49fd-28dd-413c-9743-aa3e69e4807d',
                                                                   computer_name: 'MOCK-HOST')
  end

  # The cluster's own view of its nodes: state and votes, one call for all of them,
  # and it does not need WinRM on the node to answer.
  def test_lists_the_cluster_nodes
    nodes = @client.clusters.first.nodes

    assert_equal ['mock-host', 'mock-node2'], nodes.map(&:name)
    assert(nodes.all? { |n| n.is_a? Fog::Hyperv::Compute::ClusterNode })
    assert_equal [0, 0], nodes.map(&:state)
    assert_equal ['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002'],
                 nodes.map(&:node_instance_id)
    assert_equal 9600, nodes.first.build_number
    assert_equal 'MOCK-NODE2', nodes.last.host.name
  end

  # Node names come back in whatever case the cluster holds, and Windows does not
  # distinguish them
  def test_a_cluster_node_can_be_asked_for_in_any_case
    assert_equal 'mock-host', @client.cluster_nodes.get('MOCK-HOST').name
    assert_raises(Fog::Errors::NotFound) { @client.cluster_nodes.get('MOCK-NODE3') }
  end

  # The cluster's own networks are not the switches a machine connects to, but a
  # validation report says so with them: a node with no cluster network cannot take
  # part in a failover.
  def test_lists_the_cluster_networks
    networks = @client.clusters.first.networks

    assert_equal ['Cluster Network 1', 'Cluster Network 2'], networks.map(&:name)
    assert(networks.all? { |n| n.is_a? Fog::Hyperv::Compute::ClusterNetwork })
    assert_equal ['mock-host', 'mock-node2'], networks.first.nodes
    assert_equal '10.10.10.0', networks.first.infrastructure_address
    assert_equal 100, @client.cluster_networks.get('Cluster Network 2').metric
  end

  # Quorum is one thing per cluster and nothing about it is addressable, so it comes
  # back as the hash the cmdlet gives. The numbers are the cmdlet's own: what they
  # mean is a lab capture, not something to branch on yet.
  def test_reports_the_quorum
    quorum = @client.clusters.first.quorum

    assert_equal 0, quorum[:quorum_type]
    assert_nil quorum[:quorum_resource]
    assert_equal 'mock-cluster', quorum[:cluster][:name]
  end

  # A cluster that is not there has nothing to report, and must not raise on the way
  def test_a_cluster_that_is_not_there_has_nothing_to_report
    absent = Fog::Hyperv::Compute::Cluster.new(service: @client)

    assert_empty absent.networks
    assert_empty absent.nodes
    assert_empty absent.roles
    assert_empty absent.shared_volumes
    assert_empty absent.available_disks
    assert_empty absent.quorum
  end

  # Free disks are reported as the raw hashes the cmdlet answers with: a caller shows
  # them, it never acts on one.
  def test_reports_the_disks_that_are_not_in_a_volume_yet
    disks = @client.clusters.first.available_disks

    assert_equal 1, disks.count
    assert_equal 3, disks.first[:number]
    assert_equal 536_870_912_000, disks.first[:raw_disk_size]
    assert_nil disks.first[:friendly_volume_name]
  end

  def test_a_cluster_that_is_not_there_anymore_does_not_reload
    cluster = Fog::Hyperv::Compute::Cluster.new(service: @client, id: '00000000-0000-0000-0000-000000000000')

    assert_nil cluster.reload
  end

  # --------------------------------------------------------------- capability probes

  # A consumer decides whether to ask about clusters from this one call, so the
  # question has to be answerable by a mocked client too. Until Mock grew its own
  # probes the answer was NoMethodError behind a respond_to? gate, which sent every
  # consumer's cluster path down the stand-alone branch in a mocked test.
  def test_a_mocked_client_says_it_belongs_to_a_cluster
    assert_predicate @client, :supports_clusters?
  end

  def test_a_mocked_client_says_it_manages_hyper_v
    assert_predicate @client, :valid?
  end

  # A probe with nothing to read says no, as the real probes do when WMI refuses: a
  # capability question never raises at a caller that asked it politely
  def test_a_capability_probe_with_no_data_answers_false
    @client.define_singleton_method(:handle_mock_response) do |*_args, **_opts|
      raise Fog::Errors::MockNotImplemented, 'no mocked data'
    end

    refute_predicate @client, :supports_clusters?
    refute_predicate @client, :valid?
  end
end
