# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # The Cluster Shared Volumes of the cluster the endpoint belongs to. CSVs are the
    # storage a clustered virtual machine's disks have to live on, so this is where a
    # placement decision reads its choices from.
    #
    # Like Get-ClusterNode this runs on any node of the cluster and answers about that
    # node's cluster, which is why the compute resource's endpoint has to be a node
    # and never the cluster name.
    def get_cluster_shared_volume(id: nil, **options)
      run_cmdlist(
        [
          ['$Cluster = Get-Cluster', { _by_id: id }],
          ['$Cluster | Get-ClusterSharedVolume', options]
        ]
      )
    end
  end

  class Mock
    def get_cluster_shared_volume(**args)
      data = handle_mock_response(**args)
      data = data.select { |volume| volume[:name].casecmp(args[:name].to_s).zero? } if args[:name]
      data
    end
  end
end
