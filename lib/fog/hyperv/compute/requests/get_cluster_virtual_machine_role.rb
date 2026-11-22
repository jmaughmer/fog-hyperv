# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/cluster_role'

    # The clustered roles Hyper-V virtual machines run as. A virtual machine fails
    # over only when it has one of these, and the role — not Get-VM — is what says
    # which node owns the machine now: Get-VM on a node answers for the machines
    # that node can see, so after a failover the role is where the plugin looks.
    #
    #   get_cluster_virtual_machine_role(vm_id: 'e8f37f42-…')  # one machine, by GUID
    #   get_cluster_virtual_machine_role(name: 'Virtual Machine web01')
    #   get_cluster_virtual_machine_role                        # every role
    #
    # Returns one role hash for a filtered read, an array of role hashes when
    # unfiltered, or nil when the cluster positively answered that nothing matches.
    # Everything else raises: this read licenses destroying a virtual machine's
    # disks downstream, so "absent" is returned only on a positively classified
    # answer and every other state stays an error.
    #
    # Why it is written the way it is (lab-measured, Server 2025 / FailoverCluster
    # 26100, evidence sections 34-35 and 36.2):
    #
    # - Get-ClusterVirtualMachineRole does not exist on this build, so it can never
    #   answer at all; the role read is Get-ClusterGroup, which does.
    # - -VMId matching nothing THROWS rather than returning empty, and the all-zero
    #   GUID binds as "no filter at all" and enumerates the whole cluster — so the
    #   identifier is validated on this side before anything goes on the wire, and
    #   a miss is classified from the error's FullyQualifiedErrorId, captured in the
    #   same shell, not from anything the message text says.
    # - One shell answers two questions: which cluster is answering, and what its
    #   group list says. A node whose cluster service is down cannot produce the
    #   cluster identity at all, so "no role" is only ever read while the cluster is
    #   provably answering on the same endpoint.
    def get_cluster_virtual_machine_role(**options)
      # Only vm_id and name are recognised as filters, and an unrecognised one is
      # refused rather than dropped: a filter this request does not implement would
      # otherwise turn a question about one machine into a read of every role on the
      # cluster, which is the failure this whole request is built to prevent. The _-
      # prefixed keys are fog's own call metadata (the return-field list the
      # collection adds) and are never filters.
      unknown = options.keys.reject { |key| key.to_s.start_with?('_') || %i[vm_id name].include?(key) }
      unless unknown.empty?
        raise ArgumentError,
              "get_cluster_virtual_machine_role cannot filter on #{unknown.join ', '}; it reads by " \
              'vm_id or name, and a filter it cannot apply would widen the read to every role'
      end

      vm_id = Fog::Hyperv::Utils::ClusterRole.validate_role_identifier!(options[:vm_id], __method__) unless options[:vm_id].nil?
      name = Fog::Hyperv::Utils::ClusterRole.validate_role_name!(options[:name], __method__) unless options[:name].nil?

      script = Fog::Hyperv::Utils::ClusterRole.build_read_script(vm_id: vm_id, name: name)
      out = run_cmd(script, _skip_json: true)
      rows = Fog::Hyperv::Utils::ClusterRole.parse_role_read(out.stdout, vm_id: vm_id, name: name)
      single = vm_id || name

      # A filtered read that came back with nothing is the cluster having answered
      # "no such role" — parse_role_read only lets that through on a classified
      # miss — and fog's own contract reads a miss as nil, which is what the
      # collection turns into NotFound.
      return nil if single && rows.empty?

      single ? rows.first : rows
    rescue Fog::Hyperv::Errors::PSError => e
      # The shell dies before printing its answer whenever a leg fails for a state
      # the script does not catch: leg 1 refusing a node whose cluster service
      # cannot answer, or any fault at all. The measured "nothing matched" misses
      # print their FullyQualifiedErrorId and exit clean, so anything reaching here
      # is unclassified by contract — but the error record's own text is checked
      # first anyway, and only the measured prefixes stop it from raising. The
      # VM-exists-no-role arm's discriminator was never captured, so it stays an
      # error, like a down cluster, a permissions fault, or any unmeasured shape.
      return nil if Fog::Hyperv::Utils::ClusterRole.not_found_fqe?(Fog::Hyperv::Utils::ClusterRole.extract_fqe(e.stderr))

      raise
    end
  end

  class Mock
    # Mirrors the real request's answer shapes for fixture data: a filtered read
    # returns the matching role, unfiltered returns every role. The fixture is
    # trusted by definition — which is exactly what the real request refuses to do
    # with a live answer — so the real side's cluster witness and envelope checks
    # have no fixture counterpart; the identifier and filter guards do, because a
    # refused identifier or filter is a caller bug on either side of the contract.
    def get_cluster_virtual_machine_role(**options)
      # The same filter whitelist as the real request, mirrored so a caller that
      # hands in a filter this contract cannot apply sees it in a test rather than
      # meeting it on a cluster.
      unknown = options.keys.reject { |key| key.to_s.start_with?('_') || %i[vm_id name].include?(key) }
      unless unknown.empty?
        raise ArgumentError,
              "get_cluster_virtual_machine_role cannot filter on #{unknown.join ', '}; it reads by " \
              'vm_id or name, and a filter it cannot apply would widen the read to every role'
      end

      data = handle_mock_response(**options)
      vm_id = Fog::Hyperv::Utils::ClusterRole.validate_role_identifier!(options[:vm_id], __method__) unless options[:vm_id].nil?
      name = Fog::Hyperv::Utils::ClusterRole.validate_role_name!(options[:name], __method__) unless options[:name].nil?

      if vm_id
        # The fixture stores the machine GUID under virtual_machine_id; a real
        # ClusterGroup answers VmID, which the real request mirrors onto both keys
        # so readers on either name get the same value.
        match = data.find { |role| role[:virtual_machine_id].to_s.casecmp(vm_id).zero? }
        return match ? [match] : []
      end

      if name
        match = data.find { |role| role[:name].casecmp(name).zero? }
        return match ? [match] : []
      end

      data
    end
  end
end
