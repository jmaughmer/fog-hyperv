# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/cluster_capacity'

    # The Cluster Shared Volumes of the cluster the endpoint belongs to. CSVs are the
    # storage a clustered virtual machine's disks have to live on, so this is where a
    # placement decision reads its choices from.
    #
    #   get_cluster_shared_volume                                   # every volume
    #   get_cluster_shared_volume(id: 'becc0c8a-…')                 # of one expected cluster
    #   get_cluster_shared_volume(name: 'Cluster Volume1')          # one volume by name
    #
    # Returns an array of flat volume hashes — name, id, state (2 = Online,
    # 3 = Offline, both measured), owner_node, volume_path (nil unless the mount
    # directory exists on the dialled node), size, free_space, percent_free,
    # fault_state, maintenance_mode, redirected_access — or raises. Nothing here
    # guesses: the read witnesses the answering cluster before trusting any volume
    # list, refuses an answer that cannot be attributed to that witness, and refuses
    # rows whose shape the measured cmdlet cannot produce. A filtered read that
    # matches nothing answers with an empty array — the cluster answered, the filter
    # just matched no volume — which is the collection's NotFound. A cluster with no
    # Cluster Shared Volumes at all (VMs on SMB 3.0 / Scale-Out File Server shares,
    # a newly formed cluster) answers the same empty array: the witness matched,
    # zero volumes is what the cluster has, and placement refuses that in the
    # caller's own words.
    #
    # Why it is a script and not the cmdlet pipeline (lab-measured, Server 2025 /
    # FailoverCluster 26100, evidence sections 2, 29, 30, 33.1 and 34.5, restated in
    # Fog::Hyperv::Utils::ClusterCapacity): fog's old `Get-Cluster |
    # Get-ClusterSharedVolume` pipeline reached the caller with a type-name string
    # where the volume object should have been — nil path, nil size, nil free space
    # for every volume on a healthy cluster — and the property the old model read
    # (SharedVolume.VolumePath) does not exist at any depth.
    #
    # Like Get-ClusterNode this runs on any node of the cluster and answers about
    # that node's cluster, which is why the compute resource's endpoint has to be a
    # node and never the cluster name. `id:` is the identifier of the cluster the
    # caller expects — the witness leg's cluster id is checked against it, and a
    # different cluster answering is refused rather than quietly becoming the
    # expected cluster's volumes.
    def get_cluster_shared_volume(id: nil, name: nil, **options)
      # Only id and name are recognised, and an unrecognised option is refused
      # rather than dropped: an option this request cannot honour would otherwise
      # silently widen or skew a placement read. The _-prefixed keys are fog's own
      # call metadata and pass through.
      unknown = options.keys.reject { |key| key.to_s.start_with?('_') }
      unless unknown.empty?
        raise ArgumentError,
              "get_cluster_shared_volume cannot honour #{unknown.join ', '}; it reads every volume of " \
              'the cluster behind the endpoint, optionally checked against an expected cluster id ' \
              'or narrowed to one volume name'
      end

      cluster_id = id.to_s.strip
      unless cluster_id.empty? || cluster_id.match?(Fog::Hyperv::Utils::ClusterCapacity::GUID_SHAPE)
        raise ArgumentError,
              'get_cluster_shared_volume takes the expected cluster as a canonical GUID, so the ' \
              'answering cluster can be checked against it'
      end

      script = Fog::Hyperv::Utils::ClusterCapacity.build_read_script
      out = run_cmd(script, _skip_json: true)
      rows = Fog::Hyperv::Utils::ClusterCapacity.parse_capacity_read(out.stdout, cluster_id: cluster_id)

      # The name filter runs on this side because the projection is a handful of
      # rows: nothing needs to be quoted into remote script text, and Windows
      # names are matched case-insensitively, as the cmdlet's own -Name did.
      rows = rows.select { |row| row[:name].casecmp(name.to_s.strip).zero? } unless name.nil?
      rows
    end
  end

  class Mock
    # Mirrors the real request's answer shapes for fixture data. The fixture is
    # trusted by definition — which is exactly what the real request refuses to do
    # with a live answer — so the real side's cluster witness and envelope checks
    # have no fixture counterpart; the expected-cluster identifier and the option
    # guard do, because a refused identifier or option is a caller bug on either
    # side of the contract.
    def get_cluster_shared_volume(id: nil, name: nil, **options)
      unknown = options.keys.reject { |key| key.to_s.start_with?('_') }
      unless unknown.empty?
        raise ArgumentError,
              "get_cluster_shared_volume cannot honour #{unknown.join ', '}; it reads every volume of " \
              'the cluster behind the endpoint, optionally checked against an expected cluster id ' \
              'or narrowed to one volume name'
      end

      cluster_id = id.to_s.strip
      unless cluster_id.empty? || cluster_id.match?(Fog::Hyperv::Utils::ClusterCapacity::GUID_SHAPE)
        raise ArgumentError,
              'get_cluster_shared_volume takes the expected cluster as a canonical GUID, so the ' \
              'answering cluster can be checked against it'
      end

      data = handle_mock_response(**options)
      return data if name.nil?

      data.select { |volume| volume[:name].to_s.casecmp(name.to_s.strip).zero? }
    end
  end
end
