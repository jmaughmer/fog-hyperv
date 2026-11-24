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
# mutating cmdlets' answer IS the drive. Set reflects the caller's -Path the way
# Set-VMDvdDrive does, and Add hands back a drive with no media in it, which is
# what Add-VMDvdDrive without -Path produces on the lab node.
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

  def test_a_mocked_attach_answers_the_drive_holding_the_file
    drive = @client.set_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID, path: ISO)

    assert_equal ISO, drive[:path],
                 'the caller checks its own work by reading the path back, so the Mock has to reflect it'
  end

  def test_a_mocked_eject_answers_the_drive_with_the_media_gone
    drive = @client.set_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID, path: nil)

    assert_nil drive[:path],
               'ejecting is setting the path to nothing, and the answer has to say so'
  end

  def test_a_mocked_remove_answers_without_raising
    answer = @client.remove_vm_dvd_drive(id: DRIVE_ID, vm_id: VM_ID)

    # The request skips JSON, so the Real answer is raw command output and
    # DvdDrive#destroy ignores it in favour of returning true. nil keeps a test
    # from mistaking the answer for a drive.
    assert_nil answer
  end

  # --- the model path those Mocks exist for -----------------------------------

  def test_the_dvd_drive_model_can_be_read_and_attached_under_mock
    # The collection is vm-scoped (requires :vm_id on the collection itself, so
    # that new/get can merge it into every model it answers), so the entry point
    # is dvd_drives(vm_id:) and only the drive identity is a get argument.
    drive = @client.dvd_drives(vm_id: VM_ID).get(DRIVE_ID)

    assert_equal DRIVE_ID, drive.id
    assert_nil drive.path

    # fog-hyperv models track their own diff: the caller assigns the attribute
    # and update() sends only what changed (changed! guards every field).
    drive.path = ISO
    drive.update

    assert_equal ISO, drive.path,
                 'DvdDrive#update merges the request answer back into the model, which is how iso_attach reads its own work'
  end

  def test_the_dvd_drive_model_can_be_ejected_under_mock
    drive = @client.dvd_drives(vm_id: VM_ID).get(DRIVE_ID)
    drive.path = ISO
    drive.update

    assert_equal ISO, drive.path

    # The eject detach(52) performs: path goes back to nil, and the answer the
    # model merges back must not keep claiming the old file.
    drive.path = nil
    drive.update

    assert_nil drive.path,
               'an eject through the model must answer path: nil, not the file that was in it'
  end
end
