# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # The clustered roles Hyper-V virtual machines are running as. A virtual machine
    # only fails over when it has one of these, and the role — not Get-VM — is what
    # says which node owns the machine now: Get-VM on a node answers for the machines
    # that node can see, so after a failover the role is where the plugin looks.
    #
    # Get-ClusterVirtualMachineRole is not documented the way its siblings are, so
    # the -VMId form is the part to confirm first in the lab: Get-ClusterGroup -VMId
    # is documented and returns the same objects, so it is the fallback if this
    # cmdlet turns out not to take the parameter.
    def get_cluster_virtual_machine_role(id: nil, **options)
      run_cmdlist(
        [
          ['$Cluster = Get-Cluster', { _by_id: id }],
          ['$Cluster | Get-ClusterVirtualMachineRole', options]
        ]
      )
    end
  end

  class Mock
    def get_cluster_virtual_machine_role(**args)
      data = handle_mock_response(**args)
      # -VMId is filtered by the cmdlet on the host, so the mock has to filter too.
      # It reads the fixture's virtual_machine_id, which a real ClusterGroup is
      # reported to carry but does not document: if the lab capture finds the field
      # missing or named otherwise, this filter and that fixture entry are what the
      # re-capture has to fix, and Get-ClusterGroup -VMId is the fallback for the
      # real request. Name lookups are the other way round: Hyper-V names a
      # machine's role "Virtual Machine <vm name>".
      data = data.select { |role| role[:virtual_machine_id].to_s.casecmp(args[:vm_id].to_s).zero? } if args[:vm_id]
      data = data.select { |role| role[:name].casecmp(args[:name].to_s).zero? } if args[:name]
      data
    end
  end
end
