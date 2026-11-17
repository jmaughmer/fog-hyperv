# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # Make a virtual machine a clustered role, so it fails over with the cluster
    # instead of dying with the node it runs on. The machine's storage has to be on
    # cluster shared storage for this to take, which is why the plugin asks
    # Cluster#shared_volumes where to place the disks before it calls this.
    #
    # It runs on the node that owns the machine, like every other request in this
    # gem: the cluster service being configured is the local one, so there is no
    # second hop for the credentials to fail over.
    def add_cluster_virtual_machine_role(id:, computer_name: nil, **options)
      # -VMId is documented for this cmdlet, so unlike the read side this does not
      # need the Get-ClusterGroup fallback.
      run_cmd 'Add-ClusterVirtualMachineRole',
              _target_computer: computer_name,
              vm_id: id,
              **options
    end
  end

  class Mock
    def add_cluster_virtual_machine_role(**_)
      true
    end
  end
end
