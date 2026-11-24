# frozen_string_literal: true

require 'test_helper'

# FOG-21 (BD-1 fog PR-1): the bootdisk surface drives one DVD drive through its
# whole life — add it, put an ISO in it, read it back, eject, remove it — and the
# plugin's DvdDrive model has to answer the same calls under Fog.mock! the way it
# does against a real host, because that is the only way the model's own logic is
# testable at all.
#
# Two things were wrong on that path.
#
# One: get_vm_dvd_drive is one of the few requests with a Mock of its own, and its
# Mock read a local named args that the method never defined — the method takes
# **options. Every mocked read of a DVD drive therefore raised NameError before it
# looked at the fixture sitting right next to it. (get_vm_firmware.rb has the same
# shape; it is untouched here because its Mock is reached through a model that only
# asks for vm_name, which the fixture carries.)
#
# Two: the three mutating requests had no Mock at all, so they fell through to
# Mock#method_missing, which raises MockNotImplemented for a request with no
# fixture of its own — Add/Set/Remove-VMDvdDrive have none, because they are
# passthru cmdlets whose answer is the drive. So a mocked compute resource could
# read a DVD drive and then not attach a file to it.
#
# The three Mocks answer from get_vm_dvd_drive's fixture rather than growing three
# more near-identical JSON files: that fixture is the drive's answer shape, and the
# mutating cmdlets' answer IS the drive — as it was BEFORE the change, which is
# what the lab measured (see the set/eject answer tests below): the eject request's
# answer carried the file the eject had just released, while a fresh host read of
# the same drive already answered the media gone. The Mocks used to "reflect the
# caller's -Path" instead, a politeness no real host makes; a model calibrated to
# that answer would believe a mount or eject the host has not finished showing.
# Add hands back a drive with no media in it, which is what Add-VMDvdDrive without
# -Path produces on the lab node.
class UnitDvdDriveMockTest < Minitest::Test
  VM_ID = '416e49fd-28dd-413c-9743-aa3e69e4807d'
  DRIVE_ID = 'Microsoft:416E49FD-28DD-413C-9743-AA3E69E4807D\\' \
             '33972D26-7EE4-49E8-8C11-C5F761133946\\0\\1\\D'
  ISO = 'C:\\ClusterStorage\\Volume1\\foreman-bootdisk\\1\\full-host.iso'

  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
  end

  def teardown
    Fog.unmock!
  end

  # --- the read ---------------------------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  # this one test is the proof that the fixture read works at all: identity,
  # controller position and the empty-media answer are one behaviour seen three ways
  def test_a_mocked_read_of_a_dvd_drive_answers_from_the_fixture
    drive = @client.get_vm_dvd_drive(vm_id: VM_ID)

    # This is the assertion that used to be unreachable: the Mock raised NameError
    # (undefined local variable `args`) before it read anything.
    refute_nil drive, 'the fixture carries this VM, so the read has to answer'
    assert_equal DRIVE_ID, drive[:id]
    assert_equal 0, drive[:controller_number]
    assert_equal 1, drive[:controller_location]
    assert_nil drive[:path], 'the fixture drive has no media, and nil is that answer'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_the_mocked_read_filters_by_vm_the_way_the_real_one_does
    # Get-VMDvdDrive is scoped to one VM, so a drive belonging to another VM is
    # simply not there; the Mock has to keep that shape or a model learns to rely on
    # an answer no real host gives.
    assert_nil @client.get_vm_dvd_drive(vm_id: '00000000-0000-0000-0000-000000000000')
  end

  def test_the_mocked_read_still_demands_the_vm_id
    assert_raises ArgumentError do
      @client.get_vm_dvd_drive(computer_name: 'MOCK-HOST')
    end
  end

  # --- the writes -------------------------------------------------------------

  def test_a_mocked_add_answers_a_drive_with_no_media
    drive = @client.add_vm_dvd_drive(vm_id: VM_ID)

    refute_nil drive, 'Add-VMDvdDrive is -Passthru, so its answer is the new drive'
    assert_nil drive[:path], 'a drive just added has no media in it'
    assert_equal DRIVE_ID, drive[:id], 'and it answers with the identity the caller ' \
                                       'has to address it by afterwards'
  end

  def test_a_mocked_set_answers_the_drive_as_it_was_before_the_change
    # The lab measured this on a real Gen2 cluster VM: the eject request's answer
    # carried the file the eject had just released (BD-EJ3-REQUEST-ANSWER), while
    # the next fresh read of the same drive already answered it gone
    # (BD-EJ3-GET-AFTER). The Passthru object is the drive BEFORE the change. A
    # Mock that "reflected" the caller's -Path instead would let a model believe a
    # mount or eject the host has not finished showing — and on the eject side it
    # asserted an answer the transport was in fact not even sending.
    attached = @client.set_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID, path: ISO)
    ejected = @client.set_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID, path: nil)

    assert_nil attached[:path], 'the fixture drive holds no media, and that is what the answer says'
    assert_nil ejected[:path], 'the answer is the pre-change drive, not the caller wish'
    assert_equal DRIVE_ID, attached[:id], 'the answer is still the addressed drive'
  end

  def test_a_mocked_eject_request_answers_the_pre_eject_drive
    # eject_vm_dvd_drive delegates to set with path: nil, so its Mock answer is
    # the same pre-change drive the host hands back. Callers that need the after
    # state (the bootdisk detach does) read the drive again — that re-read is the
    # only answer the host guarantees.
    answer = @client.eject_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID)

    assert_equal DRIVE_ID, answer[:id]
    assert_nil answer[:path], 'the fixture drive held no media before the eject; the answer is that drive'
  end

  def test_a_mocked_remove_answers_without_raising
    answer = @client.remove_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID)

    # The request skips JSON, so the Real answer is raw command output and
    # DvdDrive#destroy ignores it in favour of returning true. nil keeps a test
    # from mistaking the answer for a drive.
    assert_nil answer
  end

  # --- the model path those Mocks exist for -----------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  # read, attach, merge-back and re-read is one behaviour — what the model object
  # holds after each step of a single drive's life — asserted from four sides
  def test_the_dvd_drive_model_can_be_read_and_attached_under_mock
    # The collection is vm-scoped (requires :vm_id on the collection itself, so
    # that new/get can merge it into every model it answers), so the entry point
    # is dvd_drives(vm_id:) and only the drive identity is a get argument.
    drive = @client.dvd_drives(vm_id: VM_ID).get(DRIVE_ID)

    assert_equal DRIVE_ID, drive.id
    assert_nil drive.path

    # fog-hyperv models track their own diff: the caller assigns the attribute
    # and update() sends only what changed (changed! guards every field). The
    # model merges the request answer back, and that answer is the pre-change
    # drive — so what a caller just wrote is NOT confirmed by the model object
    # afterwards, and the re-read below is what confirms it.
    drive.path = ISO
    drive.update

    assert_nil drive.path,
               'the merge-back carries the host pre-change answer, so the model cannot confirm its own write'

    reread = @client.dvd_drives(vm_id: VM_ID).get(DRIVE_ID)

    assert_nil reread.path, 'under the Mock the store is a fixture, so the re-read shows no media; ' \
                            'against a host this is where the mount would show'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_the_dvd_drive_model_eject_answers_the_pre_eject_drive
    drive = @client.dvd_drives(vm_id: VM_ID).get(DRIVE_ID)
    drive.path = ISO
    drive.update

    # The eject detach(52) performs: DvdDrive#update asks eject_vm_dvd_drive for
    # a path change to nil, and the answer merged back is the pre-change drive —
    # what the host was measured to hand back, file and all on a mounted drive.
    # The plugin re-reads the drive to confirm; the model does not lie about the
    # host by confirming on its behalf.
    drive.path = nil
    answer_back = drive.update

    assert_nil answer_back.path,
               'the merged-back answer is the pre-change drive (the fixture held no media)'
  end
end
