# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # Disks the cluster can see that no cluster role owns yet, the pool a new cluster
    # shared volume would be built from. Informative: nothing in Foreman provisions
    # storage onto a cluster today, and this is what a validation report would say is
    # left to put VMs on.
    def get_cluster_available_disk(id: nil, **options)
      run_cmdlist(
        [
          ['$Cluster = Get-Cluster', { _by_id: id }],
          ['$Cluster | Get-ClusterAvailableDisk', options]
        ]
      )
    end
  end
end
