# frozen_string_literal: true

class Fog::Hyperv::Compute
  # A node of a failover cluster: one of the machines that host its virtual machines.
  #
  # This is the cluster's view of the node, which is not the same as Host's: a node
  # that is down still answers Get-ClusterNode (from whichever node asked) and does
  # not answer Get-VMHost at all, so #host is what tells the two apart.
  class ClusterNode < Fog::Hyperv::Model
    # @!attribute [r] name
    #   @return [String] the node's name, as the cluster knows it
    identity :name

    # @!attribute [r] state
    #   @return [Integer] the node's state as the cmdlet reports it. The captured
    #     fixture's 0 is a node that is up; the rest of the mapping is a lab capture.
    attribute :state, type: :integer
    # @!attribute [r] node_instance_id
    #   @return [String] the cluster's GUID for this node
    attribute :node_instance_id
    # @!attribute [r] build_number
    #   @return [Integer] the Windows build the node runs, which is what a mixed
    #     cluster — the thing that blocks a rolling upgrade — is read from
    attribute :build_number, type: :integer
    # @!attribute [r] drain_status
    #   @return [Integer] whether the node is being drained of its roles, and so is
    #     on its way out and should not be chosen for anything new
    attribute :drain_status, type: :integer
    # @!attribute [r] dynamic_weight
    #   @return [Integer] the node's vote in quorum, which dynamic quorum moves about
    #     as nodes come and go
    attribute :dynamic_weight, type: :integer

    # The host this node is, as Hyper-V describes it: its paths, memory, switches and
    # machines. Raises Fog::Errors::NotFound when the node is in the cluster but not
    # reachable over WinRM, which is the difference between clustered and manageable.
    # @return [Host]
    def host
      service.hosts.get(name)
    end
  end
end
