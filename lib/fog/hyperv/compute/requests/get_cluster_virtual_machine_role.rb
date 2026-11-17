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
      # -VMId is filtered by the cmdlet on the host, and a role object does not carry
      # the id of the machine it was made for — that is why the cmdlet takes the
      # parameter at all. The mock cannot follow a GUID to a role, so it answers name
      # lookups only, which is the other way round: Hyper-V names a machine's role
      # "Virtual Machine <vm name>".
      data = data.select { |role| role[:name].casecmp(args[:name].to_s).zero? } if args[:name]
      data
    end
  end
end
