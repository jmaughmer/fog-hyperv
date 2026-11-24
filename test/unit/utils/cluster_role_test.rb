# frozen_string_literal: true

require 'test_helper'

require 'fog/json'

# The rules the clustered-role requests share. These are the guards that stand
# between "the cluster did not answer my question" and "the cluster said the
# machine has no role" — the second of which licenses destroying that machine's
# disks — so every refusal branch is tested, not just the happy path.
class UnitClusterRoleTest < Minitest::Test
  CLUSTER_GROUP_COMMAND = 'Microsoft.FailoverClusters.PowerShell.GetClusterGroupCommand'
  GUID = 'e8f37f42-5b1a-4c2d-9e6f-0a1b2c3d4e5f'
  OTHER_GUID = '416e49fd-28dd-413c-9743-aa3e69e4807d'

  def subject
    Fog::Hyperv::Utils::ClusterRole
  end

  def envelope(rows: [], miss: '', cluster_name: 'HV-CL01')
    Fog::JSON.encode(clusterName: cluster_name, miss: miss, roles: rows)
  end

  def row(name: 'role-vm', group_type: 'VirtualMachine', vm_id: GUID, owner_node: 'hv-node2', **extra)
    { name: name, groupType: group_type, vmId: vm_id, ownerNode: owner_node, state: 2, priority: 0 }.merge(extra)
  end

  # -- identifier validation --------------------------------------------------

  def test_a_canonical_guid_is_accepted_and_returned
    assert_equal GUID, subject.validate_role_identifier!(GUID, 'req')
    assert_equal GUID.upcase, subject.validate_role_identifier!(GUID.upcase, 'req')
    assert_equal GUID, subject.validate_role_identifier!("  #{GUID}  ", 'req')
  end

  # The dangerous ones: each of these would leave the remote enumeration
  # unfiltered (measured: an unbound -VMId answers with every group), so the
  # refusal has to happen client-side.
  def test_identifiers_that_would_unfilter_the_remote_query_are_refused
    [nil, '', '   ', 'not-a-guid', 'e8f37f42-5b1a-4c2d-9e6f', "#{GUID}extra",
     '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000'.upcase,
     "e8f37f42-5b1a-4c2d-9e6f-0a1b2c3d4e5'"].each do |bad|
      assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier, "expected #{bad.inspect} to be refused") do
        subject.validate_role_identifier!(bad, 'req')
      end
    end
  end

  def test_group_names_are_refused_when_empty_or_quote_bearing
    [nil, '', '  ', "it's", 'say `hi', 'cost $5', 'web*', 'web[12]', "line\nbreak"].each do |bad|
      assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier, "expected #{bad.inspect} to be refused") do
        subject.validate_role_name!(bad, 'req')
      end
    end

    ['E4-ROLETEST', 'Virtual Machine web 01', 'backup.domain.local'].each do |good|
      assert_equal good, subject.validate_role_name!(good, 'req')
    end
  end

  # -- the error classifier ---------------------------------------------------

  # Both prefixes measured against real cluster states (evidence SS34-35).
  def test_the_measured_not_found_prefixes_classify_as_absent
    ["PSArgument,#{CLUSTER_GROUP_COMMAND}",
     "ClusterObjectNotFound,#{CLUSTER_GROUP_COMMAND}",
     "psargument,#{CLUSTER_GROUP_COMMAND.downcase}",
     '  PSArgument,Microsoft.FailoverClusters.PowerShell.GetClusterGroupCommand  '].each do |fqe|
      assert subject.not_found_fqe?(fqe), "expected #{fqe.inspect} to classify as absent"
    end
  end

  # And only those: the VM-exists-no-role arm's discriminator was never
  # captured, so nothing outside this table may read as absent — a down
  # cluster, another cmdlet's failure, or a message that merely quotes the
  # token all stay unknown.
  def test_everything_outside_the_measured_table_stays_unknown
    [nil, '',
     "ClusterObjectNotFound,#{CLUSTER_GROUP_COMMAND}".sub('Cluster', 'Clustr'),
     "SomeOther,#{CLUSTER_GROUP_COMMAND}",
     'PSArgument,Microsoft.FailoverClusters.PowerShell.GetClusterNodeCommand',
     'a message saying PSArgument,GetClusterGroupCommand in passing'].each do |fqe|
      refute subject.not_found_fqe?(fqe), "expected #{fqe.inspect} to stay unknown"
    end
  end

  def test_the_fqe_is_read_from_the_error_record_line_only
    err = "Get-ClusterGroup : Cannot find\r\n" \
          "+ CategoryInfo : InvalidArgument: (:) [Get-ClusterGroup], ClusterCmdletException\r\n" \
          "+ FullyQualifiedErrorId : PSArgument,#{CLUSTER_GROUP_COMMAND}\r\n"

    assert_equal "PSArgument,#{CLUSTER_GROUP_COMMAND}", subject.extract_fqe(err)

    [nil, '', 'nothing that looks like a record', 'mentioning FullyQualifiedErrorId : but not as a record'].each do |text|
      assert_nil subject.extract_fqe(text), "expected #{text.inspect} to yield no record line"
    end
  end

  # -- the read script --------------------------------------------------------

  # The witness leg is what makes "no role" safe to read: the script asks
  # Get-Cluster who is answering before it asks Get-ClusterGroup what is
  # there, and both answers print as one JSON object. A node that cannot name
  # its cluster cannot get as far as saying a machine has no role.
  def test_the_read_script_asks_who_is_answering_before_asking_what_is_there
    script = subject.build_read_script(vm_id: GUID, name: nil)

    assert_includes script, '$cluster = Get-Cluster'
    assert_includes script, "Get-ClusterGroup -VMId ([guid]'#{GUID}')"
    assert_includes script, 'ConvertTo-Json'
  end

  def test_the_read_script_catches_the_role_legs_own_miss
    script = subject.build_read_script(vm_id: nil, name: nil)

    assert_includes script, %($ErrorActionPreference = 'Stop')
    assert_includes script, "$answer['miss'] = $_.FullyQualifiedErrorId"
    assert_includes script, '@(Get-ClusterGroup)'
  end

  def test_the_read_script_asks_the_name_filter_when_no_guid_was_given
    script = subject.build_read_script(vm_id: nil, name: 'Virtual Machine web01')

    assert_includes script, "-Name 'Virtual Machine web01'"
    refute_includes script, '-VMId'
  end

  # The builder embeds its filter as a script literal, so it runs the
  # validators itself: an identifier that would switch the remote filter off
  # must be refused here even if a caller skipped its own check.
  def test_the_read_script_refuses_values_that_would_unfilter_it
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      subject.build_read_script(vm_id: subject::EMPTY_GUID, name: nil)
    end

    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      subject.build_read_script(vm_id: nil, name: 'web*')
    end
  end

  # -- the removal script -----------------------------------------------------

  def test_the_removal_script_identifies_the_group_before_removing_anything
    script = subject.build_removal_script(GUID)

    assert_includes script, "$vmid = '#{GUID}'"
    assert_includes script, '$groups.Count -ne 1'
    assert_includes script, %($group.GroupType -ne 'VirtualMachine')
  end

  def test_the_removal_script_proves_the_removal_and_otherwise_stays_silent
    script = subject.build_removal_script(GUID)

    assert_includes script, 'Remove-ClusterGroup -Name'
    assert_includes script, 'ClusterObjectNotFound*'
    refute_includes script, 'ConvertTo-Json'
  end

  # The refusal text has to render the count by PowerShell concatenation: #{}
  # inside this heredoc is Ruby interpolation, evaluated while building the
  # script — the defect the original had (#{$groups.Count} raised here, at
  # script-build time, invisible to every mocked test).
  def test_the_removal_script_never_interpolates_remote_values_in_ruby
    script = subject.build_removal_script(GUID)

    assert_includes script, "'the role read answered ' + $groups.Count +"
    refute_includes script, '#{'
  end

  def test_the_removal_script_refuses_an_identifier_that_would_unfilter_it
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) { subject.build_removal_script(subject::EMPTY_GUID) }
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) { subject.build_removal_script(nil) }
  end

  # -- the machine id's real home (FOG-16, measured on the lab cluster) ------
  #
  # A real cluster group matched by -VMId carries VmID = NULL: the property
  # the original scripts read is not populated on the measured build, so a
  # read attributed nothing (RoleReadUninterpretable on its own match) and a
  # removal refused itself before removing (the '' -ne id arm fired). The id's
  # real home is the VM resource's VMId cluster parameter — the same value
  # the -VMId filter matches on — so both scripts resolve through it when the
  # direct property is null, and a group whose id cannot be resolved at all
  # stays refused rather than being read as agreement.

  def test_the_read_script_resolves_the_machine_id_from_the_vm_resource
    script = subject.build_read_script(vm_id: GUID, name: nil)

    assert_includes script, subject::VM_ID_HELPER, 'the read carries the shared resolution helper'
    assert_includes script, 'vmId = $vmIdText', 'the rows carry the resolved id, not the null property'
    assert_includes script, 'virtualMachineId = $vmIdText'
  end

  def test_the_removal_script_resolves_the_id_before_comparing_it
    script = subject.build_removal_script(GUID)

    assert_includes script, "$resolvedId -eq ''", 'a group whose id resolves to nothing is refused, not agreed with'
    assert_includes script, '$resolvedId -ine $vmid', 'the comparison runs on the resolved id, case-insensitively'
    refute_includes script, '([string]$group.VmID) -ne $vmid', 'the null property must not decide the comparison'
  end

  # The resolution is shared, so a fix cannot land on one script and drift
  # from the other.
  def test_both_scripts_share_one_resolution_helper
    read = subject.build_read_script(vm_id: GUID, name: nil)
    remove = subject.build_removal_script(GUID)
    helper = subject::VM_ID_HELPER

    assert_includes read, helper
    assert_includes remove, helper
    assert_includes helper, '(Get-ClusterParameter -InputObject $vmResource -Name VMId).Value',
                    'the helper resolves the id from the VM resource parameter when the property is null'
  end

  # -- the read parser --------------------------------------------------------

  # Silence is not absence: the script always prints its envelope, and every
  # measured miss arrives as a named error, never as an empty success.
  def test_empty_and_unshaped_answers_are_refused_not_read
    [[nil, 'nil stdout'], ['', 'empty stdout'], ['   ', 'blank stdout'], ['not json', 'undecodable'],
     ['[1,2]', 'array instead of object'], ['"text"', 'string instead of object']].each do |value, _why|
      assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable, "expected #{value.inspect} to be refused") do
        subject.parse_role_read(value, vm_id: GUID)
      end
    end
  end

  # The witness leg exists so that "no role" is only ever read while a cluster
  # is answering: an envelope without a cluster identity came from nowhere.
  def test_an_answer_without_an_answering_cluster_is_refused
    assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable) do
      subject.parse_role_read(envelope(miss: "PSArgument,#{CLUSTER_GROUP_COMMAND}", cluster_name: ''), vm_id: GUID)
    end

    assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable) do
      subject.parse_role_read(envelope(cluster_name: 'HV-CL02'), cluster_name: 'HV-CL01')
    end

    rows = subject.parse_role_read(envelope(rows: [row], cluster_name: 'hv-cl01'), cluster_name: 'HV-CL01', vm_id: GUID)

    # same cluster, different case, is the same cluster
    assert_equal 1, rows.size
  end

  def test_a_measured_miss_is_the_only_empty_answer
    assert_equal [], subject.parse_role_read(envelope(miss: "PSArgument,#{CLUSTER_GROUP_COMMAND}"), vm_id: GUID)
    assert_equal [], subject.parse_role_read(envelope(miss: "ClusterObjectNotFound,#{CLUSTER_GROUP_COMMAND}"), name: 'gone')
  end

  # The VM-exists-no-role state has no captured discriminator; any other caught
  # error stays an error.
  def test_an_unmeasured_miss_state_raises
    assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable) do
      subject.parse_role_read(envelope(miss: "ClusterCmdletException,#{CLUSTER_GROUP_COMMAND}"), vm_id: GUID)
    end
  end

  def test_a_filtered_read_of_nothing_without_an_error_is_refused
    assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable) do
      subject.parse_role_read(envelope(rows: []), vm_id: GUID)
    end
  end

  def test_answers_that_cannot_be_tied_to_the_machine_are_refused
    # Two groups for one machine; a group belonging to a different machine; a
    # group that is not a machine role; a group that is not the name asked for.
    [[envelope(rows: [row, row(name: 'second')]), { vm_id: GUID }],
     [envelope(rows: [row(vm_id: OTHER_GUID)]), { vm_id: GUID }],
     [envelope(rows: [row(group_type: 'ClusterGroup')]), { name: 'role-vm' }],
     [envelope(rows: [row(name: 'other-vm')]), { name: 'role-vm' }]].each do |answer, filters|
      assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable) do
        subject.parse_role_read(answer, **filters)
      end
    end
  end

  def test_a_tied_answer_is_returned_with_the_machine_id_under_both_names
    rows = subject.parse_role_read(envelope(rows: [row]), vm_id: GUID)

    assert_equal 1, rows.size
    assert_equal [GUID, GUID], rows.first.values_at(:vm_id, :virtual_machine_id)
    assert_equal 'hv-node2', rows.first[:owner_node]
  end

  # A row that already carries the machine id under the attribute name the model
  # reads keeps its own value: mirroring vm_id across is a fill-in, not an override.
  def test_a_row_carrying_virtual_machine_id_keeps_its_own_value
    rows = subject.parse_role_read(envelope(rows: [row(vm_id: '', virtualMachineId: OTHER_GUID)]), name: 'role-vm')

    assert_equal OTHER_GUID, rows.first[:virtual_machine_id]
  end

  def test_an_unfiltered_read_keeps_only_virtual_machine_groups
    rows = subject.parse_role_read(
      envelope(rows: [row, row(name: 'cluster-group', group_type: 'ClusterGroup', vm_id: ''),
                      row(name: 'other-vm', vm_id: OTHER_GUID)])
    )

    assert_equal %w[role-vm other-vm], rows.map { |r| r[:name] }
  end
end
