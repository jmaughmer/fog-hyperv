# frozen_string_literal: true

require 'test_helper'

require 'fog/json'

# The rules behind the Cluster Shared Volume read. These are the guards that stand
# between "the node did not answer my storage question" and "this cluster has these
# volumes" — the second of which licenses placing a machine's disks — so every
# refusal branch is tested, not just the happy path. The shapes refused here are the
# ones measured as real on Server 2025 (evidence sections 29, 30, 33.1): the nested
# object that serialises as a type name, the offline volume with no path, and the
# unattributable answer. A witnessed cluster answering no volumes at all is NOT
# refused — zero CSVs is a valid configuration, and the empty list is the answer
# (review F9).
class UnitClusterCapacityTest < Minitest::Test
  CLUSTER_ID = 'becc0c8a-6444-4df5-bcd8-585ebab46518'
  OTHER_CLUSTER_ID = 'f5fc878c-37c4-482a-add5-e64d370224dc'
  VOLUME_ID = 'a49ab1ad-0f1e-4a2b-9c3d-1e2f3a4b5c6d'

  def subject
    Fog::Hyperv::Utils::ClusterCapacity
  end

  def envelope(volumes: [row], cluster_name: 'HV-CL01', cluster_id: CLUSTER_ID, **overrides)
    Fog::JSON.encode({ clusterName: cluster_name, clusterId: cluster_id, volumes: volumes }.merge(overrides))
  end

  def row(name: 'Cluster Volume1', state: 2, volume_path: 'C:\\ClusterStorage\\Volume1', **extra)
    {
      name: name, id: VOLUME_ID, state: state, ownerNode: 'hv-node1', volumePath: volume_path,
      sharedVolumeInfoCount: state == 2 ? 1 : 0, size: state == 2 ? 1_073_741_824_000 : nil,
      freeSpace: state == 2 ? 703_699_976_192 : nil, percentFree: state == 2 ? 65 : nil,
      faultState: '', maintenanceMode: false, redirectedAccess: false
    }.merge(extra)
  end

  def refusal(&block)
    assert_raises(Fog::Hyperv::Errors::ClusterCapacityUninterpretable, &block)
  end

  # -- the capability ---------------------------------------------------------------

  # The behaviour probe the plan freezes: the projection and its refusals are this
  # build's code, so every client of it answers true, and an older gem answers no
  # constant at all.
  def test_the_build_advertises_the_capability
    assert_includes Fog::Hyperv::CAPABILITIES, :cluster_capacity_projection

    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    assert_predicate client, :supports_cluster_capacity_projection?
  ensure
    Fog.unmock!
  end

  # -- the mock request --------------------------------------------------------------

  # The Mock mirrors the Real answer shapes: flat rows, and an offline volume that
  # stays visibly offline (no path) rather than a row with nil where the fixture
  # says null.
  def test_the_mock_answers_with_the_flat_measured_shapes
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    rows = client.get_cluster_shared_volume

    assert_equal ['Cluster Volume1', 'Cluster Volume2', 'Cluster Volume3'], rows.map { |r| r[:name] }
    assert_equal 'C:\\ClusterStorage\\Volume1', rows.first[:volume_path]
    assert_nil rows[1][:volume_path]
  ensure
    Fog.unmock!
  end

  # Windows names match case-insensitively, as the cmdlet's own -Name did, and a
  # name that matches nothing answers with the collection's NotFound (empty here).
  def test_the_mock_filters_by_name_case_insensitively
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    assert_equal ['Cluster Volume2'], client.get_cluster_shared_volume(name: 'cluster volume2').map { |r| r[:name] }
    assert_empty client.get_cluster_shared_volume(name: 'Cluster Volume9')
  ensure
    Fog.unmock!
  end

  # A refused identifier or option is a caller bug on either side of the contract,
  # so the Mock refuses exactly what the Real refuses.
  def test_the_mock_refuses_the_caller_bugs_the_real_side_refuses
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    assert_raises(ArgumentError) { client.get_cluster_shared_volume(id: 'not-a-guid') }
    assert_raises(ArgumentError) { client.get_cluster_shared_volume(fqdn: 'anything') }
  ensure
    Fog.unmock!
  end

  # -- the script ---------------------------------------------------------------

  # The script is the whole remote contract; if it stops carrying a leg or a
  # projection field, the parser starts refusing live answers and every test here
  # still passes. These pins are what make that break loudly.
  def test_the_script_witnesses_the_answering_cluster_first
    script = subject.build_read_script

    assert_includes script, '$cluster = Get-Cluster'
    assert_includes script, 'clusterName = [string]$cluster.Name'
    assert_includes script, 'clusterId = [string]$cluster.Id'
  end

  def test_the_script_projects_every_measured_field
    script = subject.build_read_script
    projected = ['FriendlyVolumeName', '$partition.Size', '$partition.FreeSpace', '$partition.PercentFree',
                 '[int]$csv.State', '[string]$csv.OwnerNode', 'FaultState', 'MaintenanceMode',
                 'RedirectedAccess']

    assert_empty projected.reject { |field| script.include?(field) }
  end

  # The two fictions the old read depended on may never come back: there is no
  # VolumePath property and no SharedVolume (singular) property on the object. And
  # the path may never be synthesised (evidence section 34.5): the only sources are
  # the cmdlet's FriendlyVolumeName and a Test-Path of it.
  def test_the_script_carries_no_trace_of_the_old_reads_fictions
    script = subject.build_read_script
    fictions = ['VolumePath', '.SharedVolume.', 'SharedVolumesRoot']

    assert_empty fictions.select { |fiction| script.include?(fiction) }
  end

  def test_the_script_keeps_transport_noise_off_and_the_envelope_deep
    script = subject.build_read_script

    assert_includes script, "$WarningPreference = 'SilentlyContinue'"
    assert_includes script, "$ErrorActionPreference = 'Stop'"
    assert_includes script, 'ConvertTo-Json -Compress -Depth 4'
  end

  # The pipeline rules measured on this build: Select-Object -First on a cluster
  # cmdlet dies with "The pipeline has been stopped" (evidence section 2), and the
  # role removal's lessons say the same for early termination anywhere in the read.
  def test_the_script_breaks_no_measured_pipeline_rules
    script = subject.build_read_script

    refute_includes script, 'Select-Object -First'
    refute_includes script, 'Measure-Object'
  end

  # -- envelope refusals ----------------------------------------------------------

  def test_silence_is_refused_not_read_as_no_volumes
    refusal { subject.parse_capacity_read('') }
    refusal { subject.parse_capacity_read("   \n ") }
  end

  def test_undecodable_and_off_shape_answers_are_refused
    refusal { subject.parse_capacity_read('Cluster Volume1') }
    refusal { subject.parse_capacity_read('{"clusterName": "HV-CL01" oops') }
    refusal { subject.parse_capacity_read(Fog::JSON.encode([row])) }
  end

  def test_an_answer_without_the_witness_is_refused
    refusal { subject.parse_capacity_read(envelope(cluster_name: '')) }
    refusal { subject.parse_capacity_read(envelope(cluster_name: '   ')) }
  end

  def test_a_different_answering_cluster_than_the_one_named_is_refused
    refusal { subject.parse_capacity_read(envelope, cluster_name: 'OTHER-CL') }

    assert_instance_of Array, subject.parse_capacity_read(envelope, cluster_name: 'hv-cl01')
  end

  # -- the cluster id cross-check -------------------------------------------------

  def test_the_expected_cluster_id_must_match_the_answering_one
    assert_instance_of Array, subject.parse_capacity_read(envelope, cluster_id: CLUSTER_ID)
    assert_instance_of Array, subject.parse_capacity_read(envelope, cluster_id: CLUSTER_ID.upcase)
    refusal { subject.parse_capacity_read(envelope, cluster_id: OTHER_CLUSTER_ID) }
  end

  def test_a_id_check_without_an_answered_id_is_refused
    refusal { subject.parse_capacity_read(envelope(cluster_id: ''), cluster_id: CLUSTER_ID) }
    refusal { subject.parse_capacity_read(envelope(cluster_id: nil), cluster_id: CLUSTER_ID) }
  end

  def test_an_uncomparable_expected_cluster_id_is_refused
    ['not-a-guid', "#{CLUSTER_ID}x", '  x  '].each do |id|
      refusal { subject.parse_capacity_read(envelope, cluster_id: id) }
    end
    # nil and blank are "the caller does not know which cluster", which is no
    # check to run, not a failed one.
    assert_instance_of Array, subject.parse_capacity_read(envelope, cluster_id: nil)
    assert_instance_of Array, subject.parse_capacity_read(envelope, cluster_id: '   ')
  end

  # -- the witnessed zero (review F9) -------------------------------------------------

  # The witness legs matched — the cluster named itself — so an empty volume list
  # is what the cluster HAS, not a contradiction: VMs on SMB 3.0 / Scale-Out File
  # Server shares, and freshly formed clusters, are real configurations whose CSV
  # count is zero. The empty list goes home to the caller, which refuses placement
  # in the user's words; only the unattributable silence stays a refusal (tested
  # above: no name, no id, empty stdout).
  def test_a_witnessed_cluster_answering_no_volumes_is_the_empty_answer
    assert_equal [], subject.parse_capacity_read(envelope(volumes: []))
    # A null rather than an empty array is the same answer in a different coat.
    assert_equal [], subject.parse_capacity_read(Fog::JSON.encode(clusterName: 'HV-CL01', clusterId: CLUSTER_ID, volumes: nil))
    # The expected-cluster ask is answered the same way once its witness matched.
    assert_equal [], subject.parse_capacity_read(envelope(volumes: []), cluster_id: CLUSTER_ID)
  end

  # The single-volume answer must still read as a list: ConvertTo-Json on this
  # build collapses a one-element array to a bare object (evidence section 26),
  # and the callers all take arrays.
  def test_a_single_volume_answer_stays_a_list
    rows = subject.parse_capacity_read(Fog::JSON.encode(clusterName: 'HV-CL01', clusterId: CLUSTER_ID, volumes: row))

    assert_equal ['Cluster Volume1'], rows.map { |r| r[:name] }
  end

  # -- row refusals ------------------------------------------------------------------

  def test_a_row_without_a_name_is_refused
    refusal { subject.parse_capacity_read(envelope(volumes: [row(name: '')])) }
    refusal { subject.parse_capacity_read(envelope(volumes: [row(name: nil)])) }
  end

  def test_a_non_integer_state_is_refused
    refusal { subject.parse_capacity_read(envelope(volumes: [row(state: 'Online')])) }
    refusal { subject.parse_capacity_read(envelope(volumes: [row(state: nil)])) }
  end

  def test_more_shared_volume_info_entries_than_ever_measured_is_refused
    refusal { subject.parse_capacity_read(envelope(volumes: [row(sharedVolumeInfoCount: 2)])) }
    # One (online) and zero (offline) are the measured shapes and pass.
    assert_equal 1, subject.parse_capacity_read(envelope(volumes: [row])).size
    assert_equal 1, subject.parse_capacity_read(envelope(volumes: [row(state: 3, volume_path: nil)])).size
  end

  # An online volume whose path did not survive Test-Path is the contradiction that
  # sends a disk create into a missing directory; the offline volume's empty path is
  # its measured shape and passes through. The live read answers that empty string
  # where the fixture answers null, so both arrive as the same nil.
  def test_an_online_volume_without_a_mount_path_is_refused
    refusal { subject.parse_capacity_read(envelope(volumes: [row(volume_path: '')])) }
    refusal { subject.parse_capacity_read(envelope(volumes: [row(volume_path: nil)])) }

    offline = subject.parse_capacity_read(envelope(volumes: [row(state: 3, volume_path: '')]))

    assert_nil offline.first[:volume_path]
  end

  # States outside the measured pair are neither refused nor renamed here: the
  # caller filters them with an exclusion reason.
  def test_unmeasured_states_pass_through_uninterpreted
    rows = subject.parse_capacity_read(envelope(volumes: [row(state: 99)]))

    assert_equal 99, rows.first[:state]
  end

  # -- the happy path --------------------------------------------------------------

  # One whole-answer comparison rather than point checks: it proves the rows carry
  # exactly the twelve projected fields — nothing dropped, nothing invented — in
  # the flat snake_case shape PLG-14 places against, with the offline volume
  # keeping its nils.
  def test_the_measured_volume_shapes_come_back_flat_and_untouched
    volumes = [
      row,
      row(name: 'Cluster Volume2', state: 3, volume_path: nil, sharedVolumeInfoCount: 0,
          size: nil, freeSpace: nil, percentFree: nil, ownerNode: 'hv-node1'),
      row(name: 'Cluster Volume3', ownerNode: 'hv-node2', id: '0c39d470-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
          volume_path: 'C:\\ClusterStorage\\Volume3')
    ]

    assert_equal [
      { name: 'Cluster Volume1', id: VOLUME_ID, state: 2, owner_node: 'hv-node1',
        volume_path: 'C:\\ClusterStorage\\Volume1', shared_volume_info_count: 1, size: 1_073_741_824_000,
        free_space: 703_699_976_192, percent_free: 65, fault_state: '', maintenance_mode: false,
        redirected_access: false },
      { name: 'Cluster Volume2', id: VOLUME_ID, state: 3, owner_node: 'hv-node1',
        volume_path: nil, shared_volume_info_count: 0, size: nil,
        free_space: nil, percent_free: nil, fault_state: '', maintenance_mode: false,
        redirected_access: false },
      { name: 'Cluster Volume3', id: '0c39d470-5e6f-4a7b-8c9d-0e1f2a3b4c5d', state: 2, owner_node: 'hv-node2',
        volume_path: 'C:\\ClusterStorage\\Volume3', shared_volume_info_count: 1, size: 1_073_741_824_000,
        free_space: 703_699_976_192, percent_free: 65, fault_state: '', maintenance_mode: false,
        redirected_access: false }
    ], subject.parse_capacity_read(envelope(volumes: volumes))
  end
end
