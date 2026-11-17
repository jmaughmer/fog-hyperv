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
  # model is only useful to Foreman if the nodes come out as Host models.
  def test_maps_cluster_nodes_onto_hosts
    hosts = @client.clusters.first.hosts

    assert_equal 1, hosts.count
    assert_kind_of Fog::Hyperv::Compute::Host, hosts.first
    assert_equal 'MOCK-HOST', hosts.first.name
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

  def test_a_cluster_that_is_not_there_anymore_does_not_reload
    cluster = Fog::Hyperv::Compute::Cluster.new(service: @client, id: '00000000-0000-0000-0000-000000000000')

    assert_nil cluster.reload
  end
end
