# frozen_string_literal: true

class Fog::Hyperv::Compute
  # The Cluster Shared Volumes of the cluster the compute resource's endpoint belongs
  # to. There is no cluster name to scope by: the node answers about its own cluster.
  class ClusterSharedVolumes < Fog::Hyperv::Collection
    model Fog::Hyperv::Compute::ClusterSharedVolume

    get_method :get_cluster_shared_volume

    def get(name, **filters)
      super(name: name, **filters)
    end
  end
end
