# frozen_string_literal: true

require 'test_helper'

# Nothing had ever exercised the cluster read path under Fog.mock!: get_cluster has
# no Mock of its own, so it is served by Fog::Hyperv::Compute::Mock#method_missing,
# which answers any registered request that has a mock_files/<name>.json. These
# tests say which parts of that path hold and which do not, which is what the
# failover-cluster work starts from.
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

  # Cluster#hosts goes through Get-ClusterNode and then resolves every node name it
  # gets back as a host, which is why it is worth a test of its own: the cluster
  # model is only useful to Foreman if the nodes come out as Host models.
  def test_maps_cluster_nodes_onto_hosts
    hosts = @client.clusters.first.hosts

    assert_equal 1, hosts.count
    assert_kind_of Fog::Hyperv::Compute::Host, hosts.first
    assert_equal 'MOCK-HOST', hosts.first.name
  end
end
