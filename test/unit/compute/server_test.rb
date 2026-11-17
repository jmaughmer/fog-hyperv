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
  # be read from: the fixtures put mockvm2 on mock-node2.
  def test_a_clustered_machine_knows_the_node_that_owns_it
    server = @client.servers.get('mockvm2')

    assert_predicate server, :clustered?
    assert_equal 'Virtual Machine mockvm2', server.cluster_role.name
    assert_equal 'mock-node2', server.owner_node
  end

  # No role, no cluster: the answer is the host it was read from, and nothing raises
  # on the way to it. This is the path every stand-alone host takes, so it has to be
  # the quiet one.
  def test_a_machine_that_is_not_clustered_says_so
    server = Fog::Hyperv::Compute::Server.new(service: @client, name: 'mockvm9', computer_name: 'MOCK-HOST')

    assert_nil server.cluster_role
    refute_predicate server, :clustered?
    assert_equal 'MOCK-HOST', server.owner_node
  end

  # The answer is memoised with the nil, or every call would ask again
  def test_the_cluster_role_is_only_asked_for_once
    server = Fog::Hyperv::Compute::Server.new(service: @client, name: 'mockvm9', computer_name: 'MOCK-HOST')
    asks = 0
    @client.define_singleton_method(:cluster_virtual_machine_roles) do
      asks += 1
      Fog::Hyperv::Compute::ClusterVirtualMachineRoles.new(service: self)
    end

    assert_nil server.cluster_role
    assert_nil server.cluster_role
    assert_equal 'MOCK-HOST', server.owner_node
    assert_equal 1, asks
  end
end
