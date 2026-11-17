# frozen_string_literal: true

require 'test_helper'

class UnitConnectionTest < Minitest::Test
  # Fog::Hyperv::Compute::Real opens a WinRM connection on initialize, the
  # connection state checks under test do not need one
  class OfflineClient < Fog::Hyperv::Compute::Real
    def connect(_endpoint = nil)
      nil
    end
  end

  def setup
    @client = OfflineClient.new(
      hyperv_endpoint: 'http://hyperv.example:5985/wsman',
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
  end

  # run_wql resolves the xml_fragment list itself and hands back the first
  # instance of the query, so the checks read the projected field off it
  def test_valid_for_a_reachable_hyper_v_host
    @client.stub(:run_wql, { name: 'HYPERV-HOST' }) do
      assert_predicate @client, :valid?
    end
  end

  def test_invalid_when_the_query_returns_no_instance
    @client.stub(:run_wql, {}) do
      refute_predicate @client, :valid?
    end
  end

  def test_invalid_when_the_host_can_not_be_reached
    @client.stub(:run_wql, lambda { |*_args, **_opts| raise 'WSMAN: the server is not available' }) do
      refute_predicate @client, :valid?
    end
  end

  def test_supports_clusters_for_a_clustered_host
    @client.stub(:run_wql, { name: 'Cluster Group' }) do
      assert_predicate @client, :supports_clusters?
    end
  end

  def test_no_cluster_support_without_the_cluster_namespace
    @client.stub(:run_wql, lambda { |*_args, **_opts| raise 'WSMAN: invalid namespace' }) do
      refute_predicate @client, :supports_clusters?
    end
  end

  # run_wql appends the /* of the namespace itself, passing it in doubled it
  def test_cluster_query_targets_the_mscluster_namespace
    namespaces = []
    @client.define_singleton_method(:run_wql) do |_query, _namespace: nil, **_opts|
      namespaces << _namespace
      { name: 'Cluster Group' }
    end

    assert_predicate @client, :supports_clusters?
    assert_equal ['root/mscluster'], namespaces
  end

  # ---------------------------------------------------------------- other machines

  # A cluster's other nodes are reached over WinRM too, and they answer the way the
  # configured node does. Until this was derived, a second node was always asked on
  # plain HTTP/5985, so a cluster with WinRM on 5986 over HTTPS could not be
  # managed: the request went to a port nothing listens on.
  def test_a_second_node_keeps_the_configured_scheme_port_and_path
    endpoints = []
    client = offline_client('https://hyperv.example:5986/wsman', endpoints)

    client.send(:connection, 'node2')

    assert_equal ['https://node2.example:5986/wsman'], endpoints
  end

  # The other half of the same rule: the endpoint that was configured is used as it
  # was given, not rebuilt through the same code path
  def test_the_configured_endpoint_is_used_as_it_was_given
    endpoints = []
    client = offline_client('https://hyperv.example:5986/wsman', endpoints)

    client.send(:connection, '.')

    assert_equal ['https://hyperv.example:5986/wsman'], endpoints
  end

  # A port left out of the configured endpoint is the scheme's default, and that is
  # the port a second node answers on too — pinning URI's behaviour here because
  # writing 443 explicitly is what makes an https listener work
  def test_an_endpoint_without_a_port_keeps_its_scheme_and_path
    endpoints = []
    client = offline_client('https://hyperv.example/wsman', endpoints)

    client.send(:connection, 'node2')

    assert_equal ['https://node2.example:443/wsman'], endpoints
  end

  # No endpoint at all (a client built from neither endpoint nor host) keeps the
  # answer it always gave rather than raising on a nil URI
  def test_a_client_without_an_endpoint_falls_back_to_the_plain_listener
    endpoints = []
    client = offline_client(nil, endpoints)

    client.send(:connection, 'node2')

    assert_equal ['http://node2.example:5985/wsman'], endpoints
  end

  private

  # A client that records the endpoints it would connect to instead of connecting,
  # and resolves a short node name without asking a host to do it
  def offline_client(endpoint, endpoints)
    client = OfflineClient.new(
      hyperv_endpoint: endpoint,
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
    # the client's own initialize calls connect, before this recorder exists
    client.define_singleton_method(:connect) do |ep = nil|
      endpoints << ep
      nil
    end
    client.define_singleton_method(:run_cmd) do |*_args, **_opts|
      { host_name: 'node2.example' }
    end
    client
  end
end
