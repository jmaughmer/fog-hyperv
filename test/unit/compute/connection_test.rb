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
end
