# frozen_string_literal: true

class Fog::Hyperv::Compute
  # The nodes of the cluster the compute resource's endpoint belongs to. The endpoint
  # answers for its own cluster, so there is nothing to scope these by beyond asking.
  class ClusterNodes < Fog::Hyperv::Collection
    model Fog::Hyperv::Compute::ClusterNode

    get_method :get_cluster_node

    def get(name, **filters)
      super(name: name, **filters)
    end
  end
end
