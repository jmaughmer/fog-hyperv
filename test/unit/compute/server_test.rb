# frozen_string_literal: true

require 'test_helper'

class UnitServerTest < Minitest::Test
  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
  end

  def teardown
    Fog.unmock!
  end

  def test_vm_status
    server = @client.servers.first

    assert_equal 'mockvm1', server.name
    assert_equal :Off, server.state
    assert_equal :Ok, server.primary_operational_status.to_s.to_sym

    server = @client.servers[1]

    assert_equal 'mockvm2', server.name
    assert_equal :Running, server.state
    assert_equal :Ok, server.primary_operational_status.to_s.to_sym
  end

  # A clustered machine's owner is the role's OwnerNode, not the node it happened to
  # be read from: the fixtures put mockvm2 on mock-node2. The role is found by the
  # machine's GUID, because the real role group is named after the machine, not by a
  # name this side can construct.
  def test_a_clustered_machine_knows_the_node_that_owns_it
    server = @client.servers.get('mockvm2')

    assert_predicate server, :clustered?
    assert_equal 'Virtual Machine mockvm2', server.cluster_role.name
    assert_equal 'mock-node2', server.owner_node
  end

  # The GUID the lookup ran on is exposed back to the caller under both names:
  # vm_id as a real ClusterGroup carries it, and virtual_machine_id, the
  # attribute the model and the plugin have always read.
  def test_the_role_carries_the_machine_guid_under_both_names
    role = @client.servers.get('mockvm2').cluster_role

    assert_equal '20ff7fe3-fd54-425c-aa97-fbf3c2e7a868', role.vm_id
    assert_equal '20ff7fe3-fd54-425c-aa97-fbf3c2e7a868', role.virtual_machine_id
  end

  # A machine the cluster answers no role for: nothing raises on the way to the
  # answer, and the cluster question reads as a definite false. This is the path
  # every machine without a role takes, so it has to be the quiet one.
  def test_a_machine_that_is_not_clustered_says_so
    server = Fog::Hyperv::Compute::Server.new(
      service: @client,
      id: '2c60b75f-6437-4b39-b156-a90538413c1b',
      name: 'mockvm9',
      computer_name: 'MOCK-HOST'
    )

    assert_nil server.cluster_role
    refute_predicate server, :clustered?
    assert_same false, server.is_clustered
  end

  # Without a role there is nothing newer than the payload to answer from, and
  # that is right: the machine has not been moving.
  def test_a_machine_without_a_role_answers_with_the_node_it_was_read_from
    server = Fog::Hyperv::Compute::Server.new(
      service: @client,
      id: '2c60b75f-6437-4b39-b156-a90538413c1b',
      name: 'mockvm9',
      computer_name: 'MOCK-HOST'
    )

    assert_equal 'MOCK-HOST', server.owner_node
  end

  # A machine with no id cannot be asked about at all: the cluster question is nil
  # (unknown), not false, because false is the answer that licenses disk removal.
  def test_a_machine_with_no_id_cannot_be_asked
    server = Fog::Hyperv::Compute::Server.new(service: @client, name: 'mockvm9', computer_name: 'MOCK-HOST')

    assert_nil server.cluster_role
    assert_nil server.is_clustered
    assert_equal 'MOCK-HOST', server.owner_node
  end

  # The behaviour probe the plan freezes: a Server built with no payload at all
  # answers nil, which is what tells a caller this gem is the tri-state one.
  def test_a_fresh_server_reads_the_cluster_question_as_unknown
    assert_nil Fog::Hyperv::Compute::Server.new.is_clustered
    assert_equal %i[tri_state_cluster exact_host_connection], Fog::Hyperv::CAPABILITIES
  end

  # The cluster's own answer beats the payload: the VM fixtures say IsClustered is
  # false for mockvm2 while the role fixtures give it a role, and a role on the
  # cluster is what makes a machine fail over. Both sides are checked as exact
  # tri-state values — true from the cluster, false from the payload — because
  # nil (never asked) must not pass either assertion.
  def test_the_cluster_answer_beats_the_payload
    server = @client.servers.get('mockvm2')

    assert_same true, server.is_clustered
    assert_same false, server.attributes[:is_clustered]
  end

  # The answer is memoised with the nil, or every call would ask again; the
  # role, the owner built from it, and the tri-state all settle on one ask.
  def test_the_cluster_role_is_only_asked_for_once
    server = Fog::Hyperv::Compute::Server.new(
      service: @client,
      id: '2c60b75f-6437-4b39-b156-a90538413c1b',
      name: 'mockvm9',
      computer_name: 'MOCK-HOST'
    )
    asks = 0
    @client.define_singleton_method(:cluster_virtual_machine_roles) do
      asks += 1
      Fog::Hyperv::Compute::ClusterVirtualMachineRoles.new(service: self)
    end

    assert_nil server.cluster_role
    assert_equal 'MOCK-HOST', server.owner_node
    assert_equal 1, asks
  end

  # "Could not tell" is not "no role": a read that fails for a state outside the
  # measured answers raises through, and neither clustered? nor is_clustered
  # flatten it into an answer. This is the guarantee the plugin's destroy gate is
  # built on.
  def test_a_refused_cluster_read_raises_rather_than_answering
    server = Fog::Hyperv::Compute::Server.new(
      service: @client,
      id: '2c60b75f-6437-4b39-b156-a90538413c1b',
      name: 'mockvm9',
      computer_name: 'MOCK-HOST'
    )
    output = Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('', "Get-Cluster :\n+ FullyQualifiedErrorId : Boom\r\n", 1)
    @client.define_singleton_method(:get_cluster_virtual_machine_role) do |_options = {}|
      raise Fog::Hyperv::Errors::PSError.new(output, 'cluster read refused')
    end

    assert_raises(Fog::Hyperv::Errors::PSError) { server.cluster_role }
    assert_raises(Fog::Hyperv::Errors::PSError) { server.is_clustered }
  end
end
