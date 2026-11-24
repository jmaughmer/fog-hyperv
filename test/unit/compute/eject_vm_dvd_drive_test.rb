# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/requests/eject_vm_dvd_drive'

# FOG-21 (BD-1 fog PR-1): ejecting the installer ISO is its own request, not a
# set with a remembered previous state. The bootdisk transition wants "this drive,
# no media" as ONE idempotent step: the detach task can be retried after a partial
# failure (or after the host already dropped the media), and a request that read
# the drive first and refused when it was already empty would turn a retry into a
# false failure. Set-VMDvdDrive -Path $null is exactly that no-op-on-repeat, so
# this request is addressed by the drive Id (never "the first drive"), and it
# answers the ejected drive through -Passthru so the caller sees its own work,
# the same merge-back shape set_vm_dvd_drive documents.
class UnitEjectVmDvdDriveTest < Minitest::Test
  # The OfflineClient shape FOG-11 established: connect dials nothing, run_cmdlist
  # records. The request only ever reaches run_cmdlist.
  class RecordingClient < Fog::Hyperv::Compute::Real
    attr_reader :list_calls
    attr_accessor :verdict

    def initialize(options)
      @list_calls = []
      @verdict = '{}'
      super
    end

    private

    def connect(_endpoint = nil)
      @connection = Struct.new(:logger).new(Struct.new(:level).new(nil))
    end

    def run_cmdlist(commands, **options)
      @list_calls << [commands, options]
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(@verdict, '', 0)
    end
  end

  VM_ID = '1c51c4ee-df90-4cee-a9f7-218888711248'
  DRIVE_ID = 'Microsoft:416E49FD-28DD-413C-9743-AA3E69E4807D\\33972D26-7EE4-49E8-8C11-C5F761133946\\0\\1\\D'

  # The VM and drive mock_files/get_vm_dvd_drive.json carries, so the Mock tests
  # below do not depend on which test file the suite happened to load first.
  FIXTURE_VM_ID = '416e49fd-28dd-413c-9743-aa3e69e4807d'
  FIXTURE_DRIVE_ID = DRIVE_ID

  def setup
    @client = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  def call_eject(computer_name: 'HV-NODE2')
    @client.eject_vm_dvd_drive(vm_id: VM_ID, id: DRIVE_ID, computer_name: computer_name)
  end

  def recorded
    @client.list_calls.first
  end

  def commands
    recorded.first
  end

  # --- the Real request ---------------------------------------------------------

  def test_the_eject_addresses_one_drive_by_id_and_never_the_first_drive
    call_eject

    assert_equal ['$VM = Get-VM', { id: VM_ID }], commands[0]
    assert_equal ['$DVD = $VM | Get-VMDvdDrive', { _by_id: DRIVE_ID }], commands[1],
                 'the eject must target the drive the caller named, not whichever drive comes first'
  end

  def test_the_eject_writes_the_null_path_and_passes_the_drive_back
    call_eject

    assert_equal ['$DVD | Set-VMDvdDrive', { passthru: true, path: nil }], commands[2],
                 'the eject is exactly -Path $null -Passthru: the null is the eject, the ' \
                 'passthru is how the caller reads its own work'
  end

  def test_the_eject_carries_no_existence_guard_so_a_retry_is_a_no_op
    call_eject

    assert_equal 3, commands.size,
                 'read-the-drive-then-check-if-it-has-media would make the second eject of an ' \
                 'already-empty drive a failure; Set-VMDvdDrive -Path $null repeats cleanly'
    _commands, options = recorded

    assert_nil options[:skip_json], 'the answer is the ejected drive, so the JSON must not be skipped'
    assert_equal 'HV-NODE2', options[:target_computer]
  end

  # --- the Mock -----------------------------------------------------------------

  def test_under_a_mock_the_eject_answers_the_fixture_drive_with_no_media
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    media = 'C:\ClusterStorage\Volume1\foreman-bootdisk\1\full-host.iso'
    client.set_vm_dvd_drive(vm_id: FIXTURE_VM_ID, id: FIXTURE_DRIVE_ID, path: media)

    ejected = client.eject_vm_dvd_drive(vm_id: FIXTURE_VM_ID, id: FIXTURE_DRIVE_ID)

    assert_nil ejected[:path], 'the eject answer must show the media gone, not the old file'
    assert_equal FIXTURE_DRIVE_ID, ejected[:id]
  ensure
    Fog.unmock!
  end

  def test_under_a_mock_a_drive_the_vm_does_not_have_answers_nil_like_the_set
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    assert_nil client.eject_vm_dvd_drive(vm_id: FIXTURE_VM_ID, id: 'Microsoft:NOSUCHDRIVE')
  ensure
    Fog.unmock!
  end
end
