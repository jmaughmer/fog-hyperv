# frozen_string_literal: true

require 'fog/json'

module Fog
  module Hyperv
    module Utils
      # The shell and the reading rules behind the Cluster Shared Volume read, the
      # answer a placement decision picks its storage from. Like ClusterRole for the
      # role read, this lives outside the request so the guards are testable without
      # a cluster: on the measured build (Server 2025 / FailoverCluster 26100) the
      # plain cmdlet pipeline fog used to run cannot produce a usable answer at all.
      #
      # Why a script rather than fog's cmdlet-pipeline transport (measured, evidence
      # sections 2, 29, 30, 33.1 and 34.5):
      #
      # - Get-ClusterSharedVolume answers with exactly Id, Name, OwnerNode,
      #   SharedVolumeInfo (a collection) and State. There is no volume_path
      #   property at any level: the mount path is SharedVolumeInfo.FriendlyVolumeName
      #   and the capacity is SharedVolumeInfo.Partition.{FreeSpace,Size,PercentFree}.
      # - fog's transport serialises at ConvertTo-Json depth 1 by default, and at
      #   that depth SharedVolumeInfo serialises as its TYPE NAME — so every volume
      #   reached the caller with no path, no size and no free space (measured: nil
      #   for every CSV on a healthy cluster, evidence section 33.1). Raising the
      #   depth instead turns OwnerNode into the whole node object and
      #   SharedVolumeInfo into a list (evidence section 30.3), so the fix is an
      #   explicit projection of the fields placement needs, with every value a
      #   scalar before ConvertTo-Json sees it.
      # - An Offline volume carries no SharedVolumeInfo at all and has no mount
      #   directory on disk (evidence section 29), so a path may only ever come from
      #   the cmdlet AND a Test-Path on the node being dialled — never from joining
      #   the cluster's SharedVolumesRoot with the resource name, which walks into a
      #   directory that does not exist (evidence section 34.5).
      # - The state enum fog deliberately left unasserted is now measured: 2 =
      #   Online, 3 = Offline (evidence section 30.2, re-confirmed in 34.5).
      module ClusterCapacity
        module_function

        # The measured resource-state values (evidence sections 30.2 and 34.5).
        # Anything else is passed through uninterpreted for the caller to exclude
        # with a reason; only these two have been seen.
        ONLINE_STATE = 2
        OFFLINE_STATE = 3

        # Canonical GUID shape for the cluster identifier a caller may expect the
        # answering cluster to carry. Same shape rule the role read uses, restated
        # here because a capacity read and a role read must not fail to load one
        # another just to share a constant.
        GUID_SHAPE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

        # The one shell the capacity read runs. Leg 1 asks Get-Cluster who is
        # answering: a node whose cluster service cannot serve dies on that leg,
        # before anything could answer an empty volume list, so "this cluster has
        # volumes X and Y" can never be the word of a node that could not answer.
        # On a clustered node that DOES answer, an empty volume list IS the answer:
        # zero CSVs is a valid configuration (VMs on SMB 3.0 / Scale-Out File
        # Server shares, a newly formed cluster), and attribution was always the
        # open question — evidence section 29's fact that Get-ClusterSharedVolume
        # has no second source is exactly why the witness leg exists, so emptiness
        # from a witnessed cluster is returned, not refused (review F9).
        #
        # SharedVolumeInfo is a collection (evidence section 2). Exactly one entry
        # per volume was measured; a volume answering several entries with this
        # projection taking only the first would be guessing, so the count rides
        # home with the row and parse_capacity_read refuses anything but one (or
        # zero, the measured Offline shape).
        #
        # $WarningPreference is silenced for the same reason the role scripts do:
        # the clustering cmdlets print a CredSSP negotiation notice to the warning
        # stream even when they succeed (evidence sections 34.3, 34.8), and it is
        # transport noise, never an outcome.
        def build_read_script
          <<~SCRIPT
            $ErrorActionPreference = 'Stop'
            $WarningPreference = 'SilentlyContinue'
            $cluster = Get-Cluster
            $answer = [ordered]@{ clusterName = [string]$cluster.Name; clusterId = [string]$cluster.Id; volumes = @() }
            $answer['volumes'] = @(foreach ($csv in @(Get-ClusterSharedVolume)) {
              $infos = @($csv.SharedVolumeInfo | Where-Object { $null -ne $_ })
              $info = if ($infos.Count -eq 1) { $infos[0] } else { $null }
              $partition = if ($null -ne $info) { @($info.Partition)[0] } else { $null }
              $path = if ($null -ne $info) { [string]$info.FriendlyVolumeName } else { '' }
              if ($path -ne '' -and -not (Test-Path -LiteralPath $path)) { $path = '' }
              [ordered]@{
                name = [string]$csv.Name
                id = [string]$csv.Id
                state = [int]$csv.State
                ownerNode = [string]$csv.OwnerNode
                volumePath = $path
                sharedVolumeInfoCount = $infos.Count
                size = if ($null -ne $partition) { $partition.Size } else { $null }
                freeSpace = if ($null -ne $partition) { $partition.FreeSpace } else { $null }
                percentFree = if ($null -ne $partition) { $partition.PercentFree } else { $null }
                faultState = if ($null -ne $info) { [string]$info.FaultState } else { '' }
                maintenanceMode = if ($null -ne $info) { [bool]$info.MaintenanceMode } else { $false }
                redirectedAccess = if ($null -ne $info) { [bool]$info.RedirectedAccess } else { $false }
              }
            })
            ConvertTo-Json -Compress -Depth 4 -InputObject $answer
          SCRIPT
        end

        # Turn the read script's stdout into volume rows, refusing every answer
        # that cannot be tied to a cluster, or that contradicts what the cmdlet is
        # measured to be able to say:
        #
        # - empty or undecodable stdout, or anything but the one envelope object,
        #   is refused: the script always prints its answer, so silence is
        #   off-contract, not "no volumes";
        # - a missing answering cluster name or id is refused: without the witness
        #   leg the answer cannot be attributed to a cluster at all;
        # - a caller-expected cluster id that the answering cluster does not carry
        #   is refused rather than answered with another cluster's volumes;
        # - an empty volume list from a cluster that answered IS the empty list:
        #   zero CSVs is a valid cluster configuration, and "nowhere to put disks"
        #   is the caller's decision to speak, not the parser's to pre-empt;
        # - a row with no name is refused (an unusable identity), a non-integer
        #   state is refused (the projection casts to int, so a string means the
        #   answer is not the cmdlet this script speaks to), and a row claiming
        #   more than one SharedVolumeInfo entry is refused: which entry's path
        #   would be the volume's is unmeasured, and placement may not guess;
        # - an ONLINE row (state 2) whose volume path did not survive Test-Path on
        #   the dialled node is refused: an online volume without a usable mount
        #   path is exactly the contradiction that would send a disk create into a
        #   missing directory; Offline rows arrive without one (the live read
        #   answers the empty string, the fixture the absence, and both normalise
        #   to one nil — evidence section 29).
        #
        # State values other than 2 and 3, fault state, maintenance mode and
        # redirected access are passed through uninterpreted: this build only ever
        # answered 2 and 3, and the caller's job is to filter with exclusion
        # reasons, not to have fog invent names for enums it never saw.
        #
        # @param stdout [String] the raw stdout of the read script
        # @param cluster_id [String,nil] cluster id the caller expects, if it knows
        # @param cluster_name [String,nil] cluster name the caller expects, if it knows
        # @return [Array<Hash>] volume rows with :name, :id, :state, :owner_node,
        #   :volume_path, :shared_volume_info_count, :size, :free_space,
        #   :percent_free, :fault_state, :maintenance_mode, :redirected_access
        def parse_capacity_read(stdout, cluster_id: nil, cluster_name: nil)
          text = stdout.to_s.strip
          if text.empty?
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  'the shared volume read succeeded and printed nothing; the read script always prints ' \
                  'its answer, so silence is not a readable outcome'
          end

          payload = begin
            Fog::Hyperv.uncamelize(Fog::JSON.decode(text))
          rescue StandardError => e
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "the shared volume read did not answer with the JSON object this request defines (#{e.class})"
          end
          unless payload.is_a?(Hash)
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "the shared volume read answered #{payload.class} where the script emits a single object"
          end

          answer = payload[:cluster_name].to_s.strip
          if answer.empty?
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  'the shared volume read came back without the answering cluster name, so the answer ' \
                  'cannot be attributed to any cluster'
          end
          if cluster_name && answer.casecmp(cluster_name).nonzero?
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  'the shared volume read was answered by a different cluster than the one named'
          end

          expected = cluster_id.to_s.strip
          unless expected.empty?
            unless expected.match?(GUID_SHAPE)
              raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                    'the shared volume read was asked for a cluster by an identifier that is not a ' \
                    'canonical GUID, so the answering cluster cannot be checked against it'
            end
            answered = payload[:cluster_id].to_s.strip
            if answered.empty?
              raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                    'the shared volume read came back without the answering cluster id, so a read ' \
                    'asked for by cluster id cannot be attributed to the cluster it expects'
            end
            if answered.casecmp(expected).nonzero?
              raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                    'the shared volume read was answered by a different cluster than the one asked for'
            end
          end

          volumes = [payload[:volumes]].flatten.compact
          if volumes.empty?
            # The witness legs above matched, so this empty list belongs to the
            # named cluster. Zero CSVs is a valid configuration (VMs on SMB 3.0 /
            # Scale-Out File Server shares, a newly formed cluster), so the read
            # answers the empty list and callers decide what zero means: the
            # refusal belongs to placement, in the user's words, not to the
            # parser inventing a contradiction (review F9).
            return []
          end

          volumes.map { |row| validate_capacity_row!(row) }
        end

        # One row of the projection, checked against what the cmdlet is measured to
        # be able to answer. The checks are refusals, never repairs: a row that
        # passes is returned with its own values.
        def validate_capacity_row!(row)
          unless row.is_a?(Hash)
            # A scalar where a volume's hashtable belongs dies at row[:name]:
            # String#[] and Integer#[] raise TypeError, and true and false
            # answer [] to no one with a NoMethodError. The degradation class
            # is measured, not imagined — Server 2025 answers serialise nested
            # objects as bare type-name strings (§33.1, the same measured
            # shape the FOG-26 test header cites) — and [volumes].flatten
            # .compact passes any scalar through (dropping nils is compact's
            # own business). Without this guard
            # the read escaped with a raw crash instead of this util's one
            # refusal class, so a placement caller rescuing
            # ClusterCapacityUninterpretable never saw it (FOG-32; the F4
            # finding of the FOG-26 review). Refused, never repaired.
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "a shared volume row came back as #{row.class}: #{row.inspect}; the " \
                  'projection answers every volume as a hashtable, and a scalar in its ' \
                  'place means the answer was not the projection read at all'
          end

          row = row.dup

          if row[:name].to_s.strip.empty?
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  'a shared volume row came back without a name; a volume that cannot be named ' \
                  'cannot be placed onto or excluded with a reason'
          end
          row[:name] = row[:name].to_s.strip

          unless row[:state].is_a?(Integer)
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "the shared volume row named #{row[:name]} carried state #{row[:state].inspect}; " \
                  'the projection answers state as an integer (measured 2 = Online, 3 = Offline)'
          end

          count = row[:shared_volume_info_count]
          unless count.nil? || count.is_a?(Integer)
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "the shared volume row named #{row[:name]} carried a SharedVolumeInfo count that is not a number"
          end
          if count.to_i > 1
            # Multiple SharedVolumeInfo entries on one volume were never measured,
            # and the projection took none of their paths in that case (info stays
            # null), so which path this volume mounts at stays unknown.
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "the shared volume row named #{row[:name]} answered #{count} SharedVolumeInfo " \
                  'entries; only the single-entry shape has been measured, and guessing which ' \
                  'entry holds the mount path could place disks on the wrong volume'
          end

          if row[:state] == ONLINE_STATE && row[:volume_path].to_s.strip.empty?
            raise Fog::Hyperv::Errors::ClusterCapacityUninterpretable,
                  "the shared volume row named #{row[:name]} is Online but named no mount path that " \
                  'exists on the dialled node; an online volume without a usable path is the ' \
                  'contradiction that sends a disk create into a missing directory'
          end

          # One path convention for one meaning: the live read answers an Offline
          # volume's path as the empty string (the projection's [string] cast), the
          # fixture answers it as null, and callers (PLG-14's exclusion reasons)
          # must not learn two spellings of "this volume has no mount path".
          row[:volume_path] = nil if row[:volume_path].to_s.strip.empty?

          row
        end
      end
    end
  end
end
