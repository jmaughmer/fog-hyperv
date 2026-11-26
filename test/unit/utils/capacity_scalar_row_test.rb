# frozen_string_literal: true

require 'test_helper'

require 'fog/json'

# A scalar where a volume row's hashtable belongs (FOG-32). The capacity
# parser flattens [payload[:volumes]] before validating, which drops nils and
# unwraps lists but passes any other scalar straight through to
# validate_capacity_row! — where row[:name] then died outright at base:
# TypeError from String#[] and Integer#[] ("no implicit conversion of Symbol
# into Integer"), NoMethodError from true and false (base log 2026-11-26,
# confirmed by the failure report's own exception classes). The read escaped
# as a raw crash past the util's one refusal class, so a placement caller
# rescuing ClusterCapacityUninterpretable — the contract every other
# off-shape answer keeps (fog26's test file pins that class for silence,
# undecodable JSON, and every bad row) — never saw it. The guard refuses a
# scalar row with the class the rest of the read answers in. What is NOT
# touched: the row-content refusals (name, state, SharedVolumeInfo count,
# online-without-path) and the measured flat-row happy path, both pinned
# below green on both trees.
class UnitCapacityScalarRowTest < Minitest::Test
  CLUSTER_ID = 'becc0c8a-6444-4df5-bcd8-585ebab46518'

  def subject
    Fog::Hyperv::Utils::ClusterCapacity
  end

  def envelope(volumes:)
    Fog::JSON.encode({ clusterName: 'HV-CL01', clusterId: CLUSTER_ID, volumes: volumes })
  end

  def row(name: 'Cluster Volume1', state: 2, volume_path: 'C:\\ClusterStorage\\Volume1')
    {
      name: name, id: 'a49ab1ad-0f1e-4a2b-9c3d-1e2f3a4b5c6d', state: state, ownerNode: 'hv-node1',
      volumePath: volume_path, sharedVolumeInfoCount: state == 2 ? 1 : 0,
      size: state == 2 ? 1_073_741_824_000 : nil, freeSpace: state == 2 ? 703_699_976_192 : nil,
      percentFree: state == 2 ? 65 : nil, faultState: '', maintenanceMode: false,
      redirectedAccess: false
    }
  end

  def refusal(&block)
    assert_raises(Fog::Hyperv::Errors::ClusterCapacityUninterpretable, &block)
  end

  # --- the scalar rows (red at base: raw TypeError / NoMethodError) ----------

  def test_a_string_where_a_row_belongs_is_refused_as_uninterpretable
    # The measured collapse shape (fog26's header cites Server 2025's answers
    # serialising objects as bare strings, §33.1): a whole volume arriving as
    # text. Base died in String#[] with TypeError.
    refusal { subject.parse_capacity_read(envelope(volumes: 'Cluster Volume1')) }
  end

  def test_a_number_where_a_row_belongs_is_refused_as_uninterpretable
    # Base died in Integer#[] with the same TypeError — the crash class does
    # not decide which refusals exist.
    refusal { subject.parse_capacity_read(envelope(volumes: [42])) }
  end

  def test_a_boolean_where_a_row_belongs_is_refused_as_uninterpretable
    # The sibling crash: true answers [] to no one, so base raised
    # NoMethodError, not TypeError — no rescue-by-class at the crash level
    # could have caught both.
    refusal { subject.parse_capacity_read(envelope(volumes: [true])) }
  end

  # --- both-tree green pins: the refusals that already answered in kind ------

  def test_a_hash_row_missing_its_name_still_meets_the_same_refusal_class
    # The guard added ahead of it must not re-route the row-content refusals:
    # a nameless hashtable row was, and stays, ClusterCapacityUninterpretable.
    refusal { subject.parse_capacity_read(envelope(volumes: [row(name: '')])) }
  end

  def test_the_measured_row_still_answers_flat_and_untouched
    rows = subject.parse_capacity_read(envelope(volumes: [row]))

    assert_equal 1, rows.size
    assert_equal 'Cluster Volume1', rows.first[:name]
    assert_equal 2, rows.first[:state]
  end
end
