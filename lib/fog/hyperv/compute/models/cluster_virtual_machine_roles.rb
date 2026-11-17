# frozen_string_literal: true

class Fog::Hyperv::Compute
  # The clustered virtual machine roles of the cluster the compute resource's endpoint
  # belongs to.
  class ClusterVirtualMachineRoles < Fog::Hyperv::Collection
    model Fog::Hyperv::Compute::ClusterVirtualMachineRole

    get_method :get_cluster_virtual_machine_role

    def get(name, **filters)
      super(name: name, **filters)
    end
  end
end
