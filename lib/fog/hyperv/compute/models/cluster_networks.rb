# frozen_string_literal: true

class Fog::Hyperv::Compute
  # The networks of the cluster the compute resource's endpoint belongs to.
  class ClusterNetworks < Fog::Hyperv::Collection
    model Fog::Hyperv::Compute::ClusterNetwork

    get_method :get_cluster_network

    def get(name, **filters)
      super(name: name, **filters)
    end
  end
end
