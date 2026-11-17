# frozen_string_literal: true

class Fog::Hyperv::Compute
  # A Cluster Shared Volume: storage every node of the cluster can read and write at
  # the same time, and the only place a clustered virtual machine's disks may live.
  #
  # Read-only and strictly informative, like Cluster itself.
  class ClusterSharedVolume < Fog::Hyperv::Model
    # @!attribute [r] name
    #   @return [String] the cluster's name for the volume, "Cluster Volume1"
    identity :name

    # @!attribute [r] state
    #   @return [Integer] the cluster resource state. The cmdlet reports these as
    #     numbers and the number to name mapping is not asserted here: it has to be
    #     captured from a real cluster before anything acts on it.
    attribute :state, type: :integer
    # @!attribute [r] owner_node
    #   @return [String] the node that coordinates the volume's I/O right now. Not
    #     where a VM has to run — any node can reach a CSV — but what a report shows
    #     when a volume is not where the user expects it.
    attribute :owner_node
    # @!attribute [r] shared_volume
    #   @return [Hash] the volume behind the cluster object: VolumePath under
    #     C:\ClusterStorage, FileSystem, Size, FreeSpace and the like, as the cmdlet
    #     nests them
    attribute :shared_volume

    # The path a virtual machine's config and disks go on for this volume. Nested
    # because Get-ClusterSharedVolume answers with a SharedVolume object rather than
    # flat properties, and this is the one field of it anyone asks for.
    # @return [String,nil] e.g. C:\ClusterStorage\Volume1
    def volume_path
      shared_volume && shared_volume[:volume_path]
    end
  end
end
