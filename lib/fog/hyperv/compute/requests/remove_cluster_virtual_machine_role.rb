# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/cluster_role'

    # Take the clustered role away from a virtual machine, leaving the machine and
    # its disks where they are. This has to happen before the machine is deleted or
    # its disks are freed: a role still holding the machine keeps both, and a
    # half-removed role leaves the cluster trying to start a machine that is gone.
    #
    #   remove_cluster_virtual_machine_role(id: 'e8f37f42-…', computer_name: 'hv-node2')
    #
    # id is the virtual machine's GUID — the identifier callers hold. The script it
    # is built into (ClusterRole.build_removal_script) carries the whole remote
    # decision: resolve the group from the GUID, assert one match / GroupType
    # VirtualMachine / matching VmID before deleting anything, remove with -Force
    # -RemoveResources, and require the measured ClusterObjectNotFound read-back
    # miss before the removal counts as proven.
    #
    # The identifier check below is load-bearing in a way it is not for the read:
    # options are compacted before reaching the wire, a nil id is simply dropped,
    # and Get-ClusterGroup without its filter answers with EVERY group on the
    # cluster — an id that fails to bind is not a request that matches nothing, it
    # is a request that matches everything. Nothing about this call is allowed to
    # depend on an identifier having bound.
    def remove_cluster_virtual_machine_role(id:, computer_name: nil, **_options)
      vm_id = Fog::Hyperv::Utils::ClusterRole.validate_role_identifier!(id, __method__)
      script = Fog::Hyperv::Utils::ClusterRole.build_removal_script(vm_id)

      out = run_cmd(script, _skip_json: true, _target_computer: computer_name)
      # The script prints nothing on any path: success is the exit code plus an
      # empty stdout, and stdout that is not empty is an answer this contract does
      # not describe. The remote session's CredSSP notice is silenced at the
      # warning stream for exactly this reason — it is transport noise, never an
      # outcome, and nothing here greps for it.
      unless out.stdout.to_s.strip.empty?
        raise Fog::Hyperv::Errors::RoleReadUninterpretable,
              'the clustered role removal printed a result body; it emits none, so what came back ' \
              'is not the answer this request defines'
      end

      true
    end
  end

  class Mock
    # Fixtures stand in for the cluster's answer, but the identifier guard is the
    # caller-error half of the contract and it runs here too: a nil, blank, or
    # all-zero id must fail on the mock exactly as it fails for real, because the
    # real failure mode (an unfiltered enumeration) is the dangerous one and tests
    # have to be able to see it refused. The target node is accepted and ignored —
    # there is no cluster to aim a fixture at.
    def remove_cluster_virtual_machine_role(id:, **_options)
      Fog::Hyperv::Utils::ClusterRole.validate_role_identifier!(id, __method__)
      true
    end
  end
end
