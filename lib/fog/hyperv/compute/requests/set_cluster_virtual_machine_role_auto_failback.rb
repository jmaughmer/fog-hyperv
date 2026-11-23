# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # Set automatic failback on a clustered virtual machine — the one
    # high-availability setting this cluster build accepts as a write on a
    # VM-role group (measured on HV-CL01, evidence section 60: the
    # AutoFailbackType property sticks; Priority and the failback window refuse
    # with "Unable to save property changes", and preferred owners silently
    # no-op, so this request writes the one knob and reports the rest honestly
    # through the role read).
    #
    # Runs against the cluster the machine's role lives on, like every other
    # role request. The setting is not considered applied until a fresh read of
    # the group agrees; a cluster that refuses answers
    # Fog::Hyperv::Errors::RolePropertyWriteRefused carrying its own words, and
    # a machine that is not clustered answers
    # Fog::Hyperv::Errors::ClusterRoleNotFound — a read may report "no role",
    # but a write has nothing to configure then.
    #
    # @param id [String] the machine GUID whose role carries the setting
    # @param auto_failback [true,false] exactly one of the two states
    # @param computer_name [String,nil] node to run the write on (the role's
    #   owner), when the connection's endpoint is not that node
    # @return [true] when the cluster took the setting and the read-back agreed
    def set_cluster_virtual_machine_role_auto_failback(id:, auto_failback:, computer_name: nil)
      # Both guards run client-side, before anything is built or dialled: a
      # bad id would widen the remote filter, and a non-boolean would make one
      # of the two states out of a value that named neither.
      Fog::Hyperv::Utils::ClusterRole.validate_role_identifier!(id, __method__)
      Fog::Hyperv::Utils::ClusterRole.validate_failback_flag!(auto_failback)

      script = Fog::Hyperv::Utils::ClusterRole.build_failback_script(id: id, enabled: auto_failback)
      out = run_cmd(script, _skip_json: true, _target_computer: computer_name)
      Fog::Hyperv::Utils::ClusterRole.parse_failback_write(out.stdout, wanted: auto_failback ? 1 : 0)
    end
  end

  class Mock
    # Mirrors the real request's answer shapes: the same client-side guards
    # fire, a fixture machine with a role answers true the way the proven write
    # does, and a fixture machine without one raises the same error the
    # cluster's measured miss produces. The fixture is re-read per call, so the
    # mocked write reports the verdict rather than mutating fixture state the
    # real cluster would keep.
    def set_cluster_virtual_machine_role_auto_failback(id:, auto_failback:, **_options)
      Fog::Hyperv::Utils::ClusterRole.validate_role_identifier!(id, __method__)
      Fog::Hyperv::Utils::ClusterRole.validate_failback_flag!(auto_failback)

      roles = handle_mock_response(_method: 'get_cluster_virtual_machine_role')
      match = roles.find { |role| role[:virtual_machine_id].to_s.casecmp(id.to_s).zero? }
      unless match
        raise Fog::Hyperv::Errors::ClusterRoleNotFound,
              'the machine has no clustered role, so there is no high-availability setting to change'
      end

      true
    end
  end
end
