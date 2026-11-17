# frozen_string_literal: true

class Fog::Hyperv::Compute
  # One of a cluster's networks: a network is a subnet the nodes share, which the
  # cluster uses for heartbeats, for live migration, or for clients to reach the
  # cluster's address through.
  #
  # Read-only and strictly informative, like Cluster itself. A virtual machine's
  # network is chosen from Get-VMSwitch, not from here.
  class ClusterNetwork < Fog::Hyperv::Model
    # @!attribute [r] name
    #   @return [String] the network's name, "Cluster Network 1" until someone gives
    #     it a better one
    identity :name

    # @!attribute [r] state
    #   @return [Integer] whether the network is up on all, some or none of the
    #     nodes. Numbers, as the cmdlet reports them: the mapping is a lab capture.
    attribute :state, type: :integer
    # @!attribute [r] role
    #   @return [Integer] what the network is allowed to carry — cluster traffic,
    #     client access to the cluster address, both, or neither
    attribute :role, type: :integer
    # @!attribute [r] metric
    #   @return [Integer] the preference order when a network could serve more than
    #     one purpose
    attribute :metric, type: :integer
    # @!attribute [r] infrastructure_address
    #   @return [String] the subnet these nodes share, e.g. 10.10.10.0
    attribute :infrastructure_address
    # @!attribute [r] nodes
    #   @return [Array<String>] the nodes with a network on this subnet. A node that
    #     is missing here cannot take part in a failover over this network, which is
    #     the one thing about cluster networks anyone acts on.
    attribute :nodes
  end
end
