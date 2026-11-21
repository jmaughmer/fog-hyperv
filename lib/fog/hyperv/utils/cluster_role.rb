# frozen_string_literal: true

require 'fog/json'

module Fog
  module Hyperv
    module Utils
      # The checks the clustered-role requests share: refusing an identifier that
      # would change what the remote cmdlet filters on, classifying the error the
      # cluster answers with, and refusing an answer that cannot be tied back to
      # the machine asked about. Both requests over the role contract do this
      # identically, so it lives here once.
      #
      # Why it is strict: on a failover cluster the read "I found no role for this
      # machine" is the answer that licenses destroying that machine's disks. A
      # nil, blank, or all-zero id silently turns the remote filter OFF rather
      # than matching nothing — measured on Server 2025 (evidence sections 34 and
      # 35), Get-ClusterGroup -VMId given the all-zero GUID answers with every
      # group on the cluster, because the binder treats an all-zero [guid] as the
      # parameter not being there at all. So a bad id is refused here, on this
      # side, before the cmdlet runs, and an answer that cannot be tied to the
      # id asked about is never flattened into "absent".
      module ClusterRole
        module_function

        # The all-zero GUID, assembled rather than written out so nothing in this
        # source tree contains a string that looks like a real machine id. It is
        # the one syntactically valid GUID that must never reach a role request.
        EMPTY_GUID = ('0' * 32).insert(8, '-').insert(13, '-').insert(18, '-').insert(23, '-').freeze

        # Canonical GUID shape, as Get-VM and Get-ClusterGroup report ids.
        # Deliberately no UUID-version check: a VM's id is whatever Hyper-V
        # generated and nothing here interprets the version nibble.
        GUID_SHAPE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

        # Characters that must never appear in a value interpolated into a quoted
        # PowerShell string: the double quote ends a double-quoted string, the
        # backtick escapes, the single quote ends a single-quoted string, $
        # starts an expansion, and * ? [ ] turn an exact -Name filter into a
        # pattern that matches an unknown set of groups — and matching a set is
        # not identifying one machine's role. Control characters are refused with
        # them: the value rides inside a script, and a newline or a NUL in a name
        # would put a line break in the middle of the statement being executed.
        # What survives this ban is hex digits and dashes (a GUID) or ordinary
        # name characters (a group name); the ban is load-bearing, not cosmetic.
        FORBIDDEN_CHARS = /["'`$*?\[\]\p{Cntrl}]/

        # The classifier's table, lower-cased because the comparison lower-cases
        # the prefix: the two FullyQualifiedErrorId prefixes measured to mean
        # "your filter matched nothing" on Get-ClusterGroup. Stored without their
        # colon so the table reads as the states, not the grammar.
        NOT_FOUND_PREFIXES = %w[psargument clusterobjectnotfound].freeze

        # Whether a FullyQualifiedErrorId names one of the two "nothing matched
        # your filter" states measured in the lab against Get-ClusterGroup
        # (Server 2025 / cluster build 26100, evidence sections 34-35):
        #
        #   PSArgument:...GetClusterGroupCommand            -VMId matched no virtual machine
        #   ClusterObjectNotFound:...GetClusterGroupCommand -Name matched no group
        #
        # Every other error — cluster down, service stopped, permissions, a
        # cmdlet that is not installed, and every shape not in this table — is
        # unknown, and unknown must not read as absent. The HResult is the same
        # 0x80131500 for all of them, so it is the prefix (stable, unlike the
        # localised message text) that discriminates. The cmdlet name is part of
        # the match on purpose: Get-Cluster and Get-ClusterNode failures are
        # different states, and an error that cannot be pinned to the cmdlet
        # whose table this is stays unknown. The comparison is case-insensitive
        # because the prefix's case is the cmdlet's, not the caller's.
        def not_found_fqe?(fully_qualified_error_id)
          fqe = fully_qualified_error_id.to_s.strip
          return false unless fqe.downcase.include?('getclustergroupcommand')

          prefix = fqe.split(',', 2).first.to_s.strip.downcase
          NOT_FOUND_PREFIXES.include?(prefix)
        end

        # Pull the FullyQualifiedErrorId out of a PowerShell stderr capture: the
        # error record writes it as a line of the form
        # `+ FullyQualifiedErrorId : <id>`. Matching the record line rather than
        # any occurrence keeps message text that merely quotes the token from
        # being classified. Returns nil when no record line is present.
        def extract_fqe(stderr)
          line = stderr.to_s.lines.map(&:strip).find { |l| l =~ /\A\+\s*FullyQualifiedErrorId\s*:/i }
          return nil unless line

          line.split(':', 2).last.strip
        end

        # Accepts a canonical-form GUID and nothing else. nil, blank, whitespace,
        # the all-zero GUID, names, partial or padded forms, and anything with
        # quote or wildcard characters are refused with InvalidRoleIdentifier
        # before anything goes on the wire — this call is the only guard, because
        # a nil identifier would simply be dropped from the request and leave the
        # remote enumeration unfiltered. Hex case is free: the comparisons that
        # matter downstream are the case-insensitive ones Windows itself does.
        def validate_role_identifier!(value, request)
          id = value.to_s.strip
          if id.empty?
            raise Fog::Hyperv::Errors::InvalidRoleIdentifier,
                  "#{request} refuses an empty machine identifier: an id that fails to bind is not a " \
                  'filter that matches nothing, it is no filter at all'
          end

          unless id.match?(GUID_SHAPE)
            raise Fog::Hyperv::Errors::InvalidRoleIdentifier,
                  "#{request} requires a canonical GUID (8-4-4-4-12 hex digits) to identify the machine, " \
                  "and got something else (#{id.length} characters)"
          end

          if id.casecmp(EMPTY_GUID).zero?
            raise Fog::Hyperv::Errors::InvalidRoleIdentifier,
                  "#{request} refuses the all-zero GUID: PowerShell binds it as no filter at all, and " \
                  'Get-ClusterGroup -VMId then answers with every group on the cluster'
          end

          id
        end

        # Accepts a cluster group name for the -Name arm. Names cannot be
        # validated as shapes (anything Hyper-V allowed as a name is legal), so
        # this bans only the characters that would end or expand the quoted
        # string the name rides in, or act as wildcards (FORBIDDEN_CHARS). A
        # name that needs those characters has to be looked up by the machine's
        # GUID instead — which is what the plugin holds and uses anyway. This is
        # a quoting guard, not an existence claim: a clean name may still match
        # no group, and that is what the measured ClusterObjectNotFound arm
        # answers.
        def validate_role_name!(value, request)
          name = value.to_s.strip
          if name.empty?
            raise Fog::Hyperv::Errors::InvalidRoleIdentifier,
                  "#{request} refuses an empty group name: nothing was asked for, so nothing may be " \
                  'concluded about what is there'
          end

          if name.match?(FORBIDDEN_CHARS)
            raise Fog::Hyperv::Errors::InvalidRoleIdentifier,
                  "#{request} refuses a group name containing quote, backtick, dollar, wildcard, or " \
                  'control characters; look the role up by the machine GUID instead'
          end

          name
        end

        # The one shell the role read runs: leg 1 asks Get-Cluster who is answering,
        # leg 2 asks Get-ClusterGroup, and the pair rides home as a single JSON
        # object on stdout — the envelope parse_role_read refuses everything else
        # than. Living here rather than inside the request keeps it testable: a Real
        # request body never runs under Fog.mock!, and a Ruby interpolation typo in
        # one of these scripts is invisible to every test until it raises on a live
        # cluster.
        #
        # Leg 1 (the witness) is what makes "no role" safe to read: a node whose
        # cluster service cannot serve dies there, before anything could answer an
        # empty list, so nothing downstream can call a machine unclustered on the
        # word of a node that could not answer. A never-clustered host fails the
        # same leg — this read never stands in for a "stand-alone host" answer.
        #
        # Leg 2 catches its own miss so the FullyQualifiedErrorId rides home inside
        # the JSON: classification has to happen against the value PowerShell
        # recorded, not against exception shapes or localised message text.
        #
        # The filter value is embedded as a literal — safe only because both
        # validators run here first, so a GUID is hex and dashes by construction and
        # a name has had its quote, backtick, dollar, wildcard, and control
        # characters refused, leaving doubled single quotes as the only escape left
        # to apply. The machine id rides per row as resolved by VM_ID_HELPER — the
        # direct VmID property is NULL for real machine-role groups on the measured
        # build — and it is duplicated under virtualMachineId because that is the
        # attribute name the model — and the plugin behind it — reads.
        # $WarningPreference is silenced because the remote session writes its
        # CredSSP negotiation notice to the warning stream on this transport; that
        # notice is transport noise, never an outcome.
        # The machine id's real home (FOG-16, measured on the lab cluster
        # 2026-11-21): a real cluster group matched by -VMId reports VmID as
        # NULL — the property is not populated on the measured build, and the
        # original scripts read nothing from it but ''. The value the -VMId
        # filter itself matches on lives on the group's `Virtual Machine`
        # resource as the VMId cluster parameter, so both scripts resolve it
        # from there when the direct property is null. Both embed this one
        # helper: a read and a removal must never disagree about which machine
        # a group belongs to.
        VM_ID_HELPER = <<~PS
          function Get-FogHypervGroupVmId {
            param ($group)
            $value = $group.VmID
            if ($null -eq $value) {
              $vmResource = @(@($group | Get-ClusterResource) | Where-Object { $_.ResourceType.Name -eq 'Virtual Machine' }) | Select-Object -First 1
              if ($null -ne $vmResource) { $value = (Get-ClusterParameter -InputObject $vmResource -Name VMId).Value }
            }
            [string]$value
          }
        PS

        def build_read_script(vm_id: nil, name: nil)
          filter =
            if vm_id
              vm_id = validate_role_identifier!(vm_id, __method__)
              "@(Get-ClusterGroup -VMId ([guid]'#{vm_id}'))"
            elsif name
              name = validate_role_name!(name, __method__)
              "@(Get-ClusterGroup -Name '#{name.gsub("'", "''")}')"
            else
              '@(Get-ClusterGroup)'
            end

          <<~SCRIPT
            $ErrorActionPreference = 'Stop'
            $WarningPreference = 'SilentlyContinue'
            #{VM_ID_HELPER}
            $cluster = Get-Cluster
            $answer = [ordered]@{ clusterName = [string]$cluster.Name; miss = ''; roles = @() }
            try {
              $groups = #{filter}
            } catch {
              $answer['miss'] = $_.FullyQualifiedErrorId
              $groups = @()
            }
            $answer['roles'] = @(foreach ($group in $groups) {
              $vmIdText = if ($group.GroupType -eq 'VirtualMachine') { Get-FogHypervGroupVmId $group } else { [string]$group.VmID }
              [ordered]@{
                name = [string]$group.Name
                groupType = [string]$group.GroupType
                vmId = $vmIdText
                virtualMachineId = $vmIdText
                ownerNode = [string]$group.OwnerNode
                state = $group.State
                priority = $group.Priority
              }
            })
            ConvertTo-Json -Compress -Depth 4 -InputObject $answer
          SCRIPT
        end

        # The one shell the role removal runs. Nothing is deleted on the strength of
        # an identifier alone: Remove-ClusterVirtualMachineRole does not exist on the
        # measured build, and the cmdlet that does, Remove-ClusterGroup, answers to a
        # NAME, so taking the name from a caller would let one GUID's removal delete
        # a different group. The group is resolved remotely from the same GUID and
        # three things are asserted in the same shell before anything is removed:
        # exactly one group matched, it is a virtual machine role, and its machine
        # id — resolved through VM_ID_HELPER, because the direct VmID property is
        # NULL on real groups — equals the one asked about; a group whose id
        # resolves to nothing is refused as unattributed, not read as agreement.
        # After the removal the shell reads the
        # group back by name and requires the one answer measured for a name that is
        # gone (the ClusterObjectNotFound miss) — an empty answer without that error
        # raises rather than reporting a removal that was not proven. -Force alone
        # does not remove a non-empty group, so -RemoveResources rides with it.
        #
        # A PSArgument miss on the pre-read is the measured answer for "no virtual
        # machine carries this id" and makes the call idempotent: there is no role to
        # remove, which is what the caller asked for.
        #
        # The script prints nothing on any path: success is the exit code plus empty
        # stdout, so stdout that is not empty is off-contract to the request. The
        # identifier is validated here — before its value becomes a script literal —
        # because an id that failed to bind on the wire would enumerate (and this
        # script would try to remove) every group on the cluster.
        def build_removal_script(vm_id)
          vm_id = validate_role_identifier!(vm_id, __method__)

          <<~SCRIPT
            $WarningPreference = 'SilentlyContinue'
            $ErrorActionPreference = 'Stop'
            #{VM_ID_HELPER}
            $vmid = '#{vm_id}'
            $miss = ''
            try {
              $groups = @(Get-ClusterGroup -VMId ([guid]$vmid))
            } catch {
              $fullyQualifiedErrorId = [string]$_.FullyQualifiedErrorId
              if ($fullyQualifiedErrorId -like 'PSArgument*') { $miss = 'PSArgument' } else { throw }
            }
            if ($miss -ne 'PSArgument') {
              if ($groups.Count -ne 1) { throw ('the role read answered ' + $groups.Count + ' groups for one machine id; exactly one is required to remove a role') }
              $group = $groups[0]
              if ($group.GroupType -ne 'VirtualMachine') { throw ('the matched cluster group is not a virtual machine role; refusing to remove it') }
              $resolvedId = Get-FogHypervGroupVmId $group
              if ($resolvedId -eq '') { throw ('the matched cluster group carries no machine id at all; refusing to remove it') }
              if ($resolvedId -ine $vmid) { throw ('the matched cluster group carries a different machine id than the one asked about; refusing to remove it') }
              $null = Remove-ClusterGroup -Name $group.Name -Force -RemoveResources
              try {
                $left = @(Get-ClusterGroup -Name $group.Name)
              } catch {
                $fullyQualifiedErrorId = [string]$_.FullyQualifiedErrorId
                if ($fullyQualifiedErrorId -notlike 'ClusterObjectNotFound*') { throw }
                $left = $null
              }
              if ($null -ne $left) {
                if ($left.Count -eq 0) { throw ('the role read-back answered no group without the measured miss error; the removal is not proven') }
                throw ('the clustered role is still present after the removal was issued')
              }
            }
          SCRIPT
        end

        # Turn the read script's stdout into role rows, refusing every answer
        # that cannot be tied to the machine asked about.
        #
        # The script is one shell: leg 1 asks Get-Cluster who is answering, leg 2
        # asks Get-ClusterGroup (catching its own miss so the
        # FullyQualifiedErrorId rides home in the JSON), and the answer is the
        # pair as one JSON object. Everything here refuses rather than guessing,
        # because the reading being avoided is "no role" — the one answer that
        # licenses destroying the machine's disks:
        #
        # - an empty or undecodable stdout is refused: the script always prints
        #   its envelope, so silence is off-contract, and "nothing matched" and
        #   "nothing printed" are different events;
        # - no answering cluster name is refused: the witness leg printed nothing
        #   usable, so the answer cannot be attributed to a cluster at all — and
        #   a node whose cluster service cannot answer looks exactly like this;
        # - a caught miss becomes an empty answer only for the two measured
        #   prefixes and a raise for everything else — including the
        #   VM-exists-no-role arm, whose discriminator has never been captured;
        # - a filtered read that answers zero rows WITHOUT a caught miss is
        #   refused (absence arrives classified above, never as a quiet empty
        #   list), and so are several rows, a group that is not GroupType
        #   VirtualMachine, a group carrying a different machine id than asked
        #   for, or a row whose name is not the name asked for;
        # - unfiltered reads keep only VirtualMachine groups, and rows come back
        #   with virtual_machine_id mirrored from vm_id: the script resolves the
        #   id through VM_ID_HELPER (the direct VmID property is NULL on real
        #   machine-role groups), while the model — and the plugin behind it —
        #   reads the attribute named virtual_machine_id.
        #
        # @param stdout [String] the raw stdout of the read script
        # @param cluster_name [String,nil] cluster the caller expects, if it knows
        # @return [Array<Hash>] role rows, with :vm_id and :virtual_machine_id
        #   carrying the machine GUID (empty only for a classified miss or a
        #   genuinely role-less cluster when unfiltered)
        def parse_role_read(stdout, cluster_name: nil, vm_id: nil, name: nil)
          text = stdout.to_s.strip
          if text.empty?
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  'the clustered role read succeeded and printed nothing; the read script always prints ' \
                  'its answer, so silence is not a readable outcome'
          end

          payload = begin
            Fog::Hyperv.uncamelize(Fog::JSON.decode(text))
          rescue StandardError => e
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  "the clustered role read did not answer with the JSON object this request defines (#{e.class})"
          end
          unless payload.is_a?(Hash)
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  "the clustered role read answered #{payload.class} where the script emits a single object"
          end

          answer = payload[:cluster_name].to_s
          if answer.empty?
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  'the clustered role read came back without the answering cluster name, so the answer ' \
                  'cannot be attributed to any cluster'
          end
          if cluster_name && answer.casecmp(cluster_name).nonzero?
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  'the clustered role read was answered by a different cluster than the one named'
          end

          miss = payload[:miss].to_s
          unless miss.empty?
            # The cluster answered, caught its own miss, and named it. Only the
            # measured prefixes may become an empty answer; anything else stays
            # an error, and the message carries the stable prefix rather than
            # whatever localised text came with it.
            return [] if not_found_fqe?(miss)

            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  "the clustered role read caught an error whose state is not in the measured table (#{miss.split(',', 2).first})"
          end

          validate_role_rows!([payload[:roles]].flatten.compact, vm_id: vm_id, name: name)
        end

        # Check the group rows of a role read against the question that produced
        # them, and return them with the machine GUID under both names the model
        # reads (:vm_id, which a real ClusterGroup carries, and
        # :virtual_machine_id, the attribute name the model and the plugin have
        # always used).
        def validate_role_rows!(rows, vm_id: nil, name: nil)
          filtered = vm_id || name

          if filtered && rows.empty?
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  'the clustered role read answered a filtered query with no rows and no miss, which is ' \
                  'not an answer this cmdlet gives; it must not be read as absence'
          end
          if filtered && rows.size > 1
            raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                  "the clustered role read answered #{rows.size} groups for one machine; one machine has " \
                  "at most one role, so the answer cannot be read as that machine's role"
          end

          rows = rows.select { |row| row[:group_type].to_s.casecmp('VirtualMachine').zero? } unless filtered

          rows.map do |row|
            row = row.dup

            if row[:group_type].to_s.casecmp('VirtualMachine').nonzero?
              raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                    "the clustered role read matched a #{row[:group_type]} group, not a virtual machine role"
            end
            if vm_id && row[:vm_id].to_s.casecmp(vm_id).nonzero?
              raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                    'the matched cluster group carries a different machine id than the one asked for'
            end
            if name && row[:name].to_s.casecmp(name).nonzero?
              raise Fog::Hyperv::Errors::RoleReadUninterpretable,
                    'the matched cluster group is not the name that was asked for'
            end

            row[:virtual_machine_id] = row[:vm_id] if row[:virtual_machine_id].to_s.empty? && row[:vm_id].to_s != ''
            row
          end
        end
      end
    end
  end
end
