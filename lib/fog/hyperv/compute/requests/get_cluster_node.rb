# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # id is optional because a node answers about the cluster it belongs to on its
    # own: filtering by cluster GUID is for the caller that already has one, and
    # ClusterNodes#get asking for one node by name has no GUID to bring.
    def get_cluster_node(id: nil, **options)
      run_cmdlist(
        [
          ['$Cluster = Get-Cluster', { _by_id: id }],
          ['$Cluster | Get-ClusterNode', options]
        ]
      )
    end
  end

  class Mock
    def get_cluster_node(**args)
      data = handle_mock_response(**args)
      # Windows names are not case sensitive and Get-ClusterNode answers with the
      # case the cluster happens to hold, so neither is this filter
      data = data.select { |node| node[:name].casecmp(args[:name].to_s).zero? } if args[:name]
      data
    end
  end
end
