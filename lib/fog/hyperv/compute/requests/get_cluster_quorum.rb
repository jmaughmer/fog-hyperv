# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # How the cluster decides it is still a cluster: node majority, or a majority with
    # a disk or file share witness behind it. The answer to "can this cluster survive
    # losing the node a machine is on" starts here, which is why Foreman would report
    # it rather than act on it.
    def get_cluster_quorum(id: nil, **options)
      run_cmdlist(
        [
          ['$Cluster = Get-Cluster', { _by_id: id }],
          ['$Cluster | Get-ClusterQuorum', options]
        ]
      )
    end
  end
end
