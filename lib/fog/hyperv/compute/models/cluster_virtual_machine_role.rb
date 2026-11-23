# frozen_string_literal: true

class Fog::Hyperv::Compute
  # A virtual machine that has been made a clustered role, and so fails over with the
  # cluster instead of dying with the node it was started on.
  #
  # Read-only and strictly informative, like Cluster itself.
  class ClusterVirtualMachineRole < Fog::Hyperv::Model
    # @!attribute [r] name
    #   @return [String] the role group's name. On the measured build the cluster
    #     names a machine's role group after the machine itself (Get-ClusterGroup
    #     answered E4-ROLETEST for the VM named E4-ROLETEST); the "Virtual Machine
    #     <name>" form is what the fixtures carry, and #vm_name reads sensibly
    #     under either.
    identity :name

    # @!attribute [r] state
    #   @return [Integer] the cluster resource state, as the cmdlet reports it; the
    #     number to name mapping is a lab capture, not something to act on yet
    attribute :state, type: :integer
    # @!attribute [r] owner_node
    #   @return [String] the node running the machine right now. This is the field the
    #     plugin has to re-read after a failover: the host a Server was created on
    #     stops being where it lives the moment the role moves.
    attribute :owner_node
    # @!attribute [r] group_type
    #   @return [String] "VirtualMachine" for a role this model describes, and
    #     something else for the cluster's own groups
    attribute :group_type
    # @!attribute [r] virtual_machine_id
    #   @return [String] the GUID of the machine this role was made for. A real
    #     ClusterGroup carries the value as VmID — measured in the lab — and the
    #     role read mirrors it onto this attribute so readers keyed on either
    #     name see the same value.
    attribute :virtual_machine_id
    # @!attribute [r] vm_id
    #   @return [String] the machine GUID as the cluster property spells it
    #     (VmID), kept alongside virtual_machine_id rather than replacing it
    attribute :vm_id
    # @!attribute [r] priority
    #   @return [Integer] the order roles fail over in when several move at once
    attribute :priority, type: :integer
    # @!attribute [r] auto_failback_type
    #   @return [Integer,nil] the cluster's AutoFailbackType verbatim: 0 is off,
    #     any other value is some flavour of on. This is the one high-availability
    #     group property the measured build accepts as a WRITE on a VM-role group
    #     (evidence section 60); #auto_failback reads it as a boolean.
    attribute :auto_failback_type, type: :integer
    # @!attribute [r] failback_window_start
    #   @return [Integer,nil] where the cluster's failback window opens, in the
    #     unit the cmdlet reports; a cluster with no window answers the
    #     4294967295 sentinel, which #failback_window reads as nil. Refused as a
    #     write on the measured build — this field is display vocabulary.
    attribute :failback_window_start, type: :integer
    # @!attribute [r] failback_window_end
    #   @return [Integer,nil] where the failback window closes, same sentinel
    #     rule as failback_window_start
    attribute :failback_window_end, type: :integer
    # @!attribute [r] preferred_node_names
    #   @return [Array<String>,nil] the cluster's preferred owners for this role:
    #     the nodes it PREFERS to run the machine on, asked group by group of
    #     Get-ClusterOwnerNode (measured source on this build — evidence
    #     section 76; the group's own PreferredNodeNames property is NULL). The
    #     three states are different claims and are kept apart verbatim: a list
    #     of names is a restricted preference, [] is the cluster's positive "no
    #     restricted list — any node may own" answer, and nil means this group's
    #     owner list could not be read — which is NOT "no restriction". Labelling
    #     them is display vocabulary; this side only carries what was answered.
    attribute :preferred_node_names

    # The value Get-ClusterGroup answers for both ends of a cluster's failback
    # window when no window is set (measured on HV-CL01, evidence section 60:
    # 4294967295..4294967295). It means "no window", not a minute of the day.
    FAILBACK_WINDOW_DISABLED = 4_294_967_295

    # The name of the virtual machine this role is the clustered form of. Matching a
    # role to a machine by name is what the mock and the -Name lookup can both do;
    # by id needs -VMId, which only the real cmdlet resolves.
    # @return [String] the machine's name, without the "Virtual Machine " prefix
    def vm_name
      name.to_s.sub(/\AVirtual Machine /, '')
    end

    # The machine GUID, preferring the value that arrived under the cmdlet's own
    # name; a role loaded from a fixture that only carries virtual_machine_id
    # still answers this, so a caller never gets nil for a GUID the model has.
    # @return [String,nil]
    def vm_id
      attributes[:vm_id] || attributes[:virtual_machine_id]
    end

    # Whether the cluster will fail this machine back on its own. Derived from
    # the raw type rather than stored: mocked fixtures and the read script then
    # answer through one rule. A role that never reported the property answers
    # nil — "not known" — not false, because false is a claim about the cluster.
    # @return [true,false,nil]
    def auto_failback
      type = attributes[:auto_failback_type]
      type.nil? ? nil : !type.to_i.zero?
    end

    # The failback window the cluster reports, with the measured "no window"
    # sentinel read as absence. The pair is returned verbatim — this side has
    # measured that the sentinel means off, not what the other unit means — so
    # display layers decide how to render it.
    # @return [Array(Integer,Integer),nil] [start, end], or nil when no window
    #   is reported or the cluster answered the disabled sentinel
    def failback_window
      start_value = attributes[:failback_window_start]
      end_value = attributes[:failback_window_end]
      return nil if start_value.nil? || end_value.nil?
      return nil if start_value.to_i == FAILBACK_WINDOW_DISABLED || end_value.to_i == FAILBACK_WINDOW_DISABLED

      [start_value, end_value]
    end
  end
end
