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
  end
end
