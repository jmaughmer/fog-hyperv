# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # Take the clustered role away from a virtual machine, leaving the machine and
    # its disks where they are. This has to happen before the machine is deleted or
    # its disks are freed: a role still holding the machine keeps both, and a
    # half-removed role leaves the cluster trying to start a machine that is gone.
    #
    # Remove-ClusterVirtualMachineRole only takes -Name or -InputObject, and callers
    # hold the machine's GUID, so the documented way to get from one to the other is
    # Get-ClusterGroup -VMId, which answers the same objects.
    def remove_cluster_virtual_machine_role(id:, computer_name: nil, **options)
      run_cmdlist(
        [
          ['$Group = Get-ClusterGroup', { vm_id: id }],
          ['$Group | Remove-ClusterVirtualMachineRole', { force: true, **options }]
        ],
        skip_json: true,
        target_computer: computer_name
      )
    end
  end

  class Mock
    def remove_cluster_virtual_machine_role(**_)
      true
    end
  end
end
