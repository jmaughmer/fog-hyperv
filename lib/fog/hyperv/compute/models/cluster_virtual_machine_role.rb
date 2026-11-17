# frozen_string_literal: true

class Fog::Hyperv::Compute
  # A virtual machine that has been made a clustered role, and so fails over with the
  # cluster instead of dying with the node it was started on.
  #
  # Read-only and strictly informative, like Cluster itself.
  class ClusterVirtualMachineRole < Fog::Hyperv::Model
    # @!attribute [r] name
    #   @return [String] the role's name, which Hyper-V derives from the machine:
    #     "Virtual Machine <vm name>"
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
  end
end
