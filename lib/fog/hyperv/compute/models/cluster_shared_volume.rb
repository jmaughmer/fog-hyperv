# frozen_string_literal: true

class Fog::Hyperv::Compute
  # A Cluster Shared Volume: storage every node of the cluster can read and write at
  # the same time, and the only place a clustered virtual machine's disks may live.
  #
  # Read-only and strictly informative, like Cluster itself.
  #
  # The fields are flat because the read projects them: Get-ClusterSharedVolume
  # nests everything a placement decision needs inside a SharedVolumeInfo
  # collection, and on the measured build (Server 2025 / FailoverCluster 26100)
  # fog's old nested answer arrived with a type-name string in its place — no
  # path, no size, no free space, on a healthy cluster (evidence sections 30,
  # 33.1). The projection lives in Fog::Hyperv::Utils::ClusterCapacity and refuses
  # on the box anything that would have to be guessed here.
  class ClusterSharedVolume < Fog::Hyperv::Model
    # @!attribute [r] name
    #   @return [String] the cluster's name for the volume, "Cluster Volume1"
    identity :name

    # @!attribute [r] id
    #   @return [String,nil] the volume's cluster GUID. A caller identifying a
    #     storage domain by id must not substitute the name for it: the read is
    #     asked for the id, and an answer that carries none stays visible as none.
    attribute :id
    # @!attribute [r] state
    #   @return [Integer] the cluster resource state. Measured on the lab cluster
    #     (evidence section 30.2, re-confirmed in 34.5): 2 = Online, 3 = Offline.
    #     Values other than these two are passed through uninterpreted — exclude
    #     them with a reason rather than treating them as either. Plain attribute
    #     rather than an integer-typed one on purpose: fog-core's integer reader
    #     turns a nil answer into 0, and this read distinguishes "the volume
    #     answered a state" from "the volume answered nothing" (the parser has
    #     already proven it is an Integer when present).
    attribute :state
    # @!attribute [r] owner_node
    #   @return [String] the node that coordinates the volume's I/O right now. Not
    #     where a VM has to run — any node can reach a CSV, and ownership is spread
    #     across nodes per volume (evidence section 29) — but what a report shows
    #     when a volume is not where the user expects it.
    attribute :owner_node
    # @!attribute [r] volume_path
    #   @return [String,nil] the mount path — C:\ClusterStorage\Volume1 — taken
    #     from SharedVolumeInfo.FriendlyVolumeName and only kept when Test-Path
    #     confirms it on the dialled node. Nil when the volume has no mount path,
    #     which is the measured Offline shape (evidence sections 29, 34.5, and the
    #     live row: an offline volume answers the projection's path as empty and
    #     the parser normalises that to one nil). It is never synthesised from the
    #     volume name.
    attribute :volume_path
    # @!attribute [r] shared_volume_info_count
    #   @return [Integer] how many SharedVolumeInfo entries the volume answered
    #     with; the read refuses anything but the measured 0 (Offline) or 1.
    attribute :shared_volume_info_count
    # @!attribute [r] size
    #   @return [Integer,nil] the volume's capacity in bytes, from
    #     SharedVolumeInfo.Partition.Size; nil when the volume carried no
    #     SharedVolumeInfo (Offline) to be read from. Kept plain for the same
    #     reason as state: a nil capacity must stay nil, not become zero.
    attribute :size
    # @!attribute [r] free_space
    #   @return [Integer,nil] bytes free, from SharedVolumeInfo.Partition.FreeSpace.
    attribute :free_space
    # @!attribute [r] percent_free
    #   @return [Numeric,nil] percent free, from SharedVolumeInfo.Partition.PercentFree;
    #     the live read answers a fraction-bearing number (98.12914), so this is
    #     not guaranteed to be a whole Integer.
    attribute :percent_free
    # @!attribute [r] fault_state
    #   @return [String] the volume's fault state as the cmdlet spells it
    #     (SharedVolumeInfo.FaultState); the live read spells the healthy state
    #     "NoFaults", and '' when there was no SharedVolumeInfo. A volume in fault
    #     is not placement storage, but the name is passed through rather than
    #     interpreted: only the lab-measured values are known.
    attribute :fault_state
    # @!attribute [r] maintenance_mode
    #   @return [Boolean] whether the volume is in maintenance mode
    #     (SharedVolumeInfo.MaintenanceMode).
    attribute :maintenance_mode
    # @!attribute [r] redirected_access
    #   @return [Boolean] whether the volume is serving redirected IO
    #     (SharedVolumeInfo.RedirectedAccess) — every node's writes then detour
    #     through the coordinator, which is a performance signal for placement.
    attribute :redirected_access
  end
end
