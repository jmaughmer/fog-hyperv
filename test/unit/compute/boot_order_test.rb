# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/utils/boot_order'
require 'fog/hyperv/compute/requests/get_vm_boot_order'
require 'fog/hyperv/compute/requests/set_vm_boot_order'

# FOG-21 (BD-1 fog PR-1): the bootdisk seam must put HDD, DVD, NIC at the front of a
# Gen2 VM's UEFI boot order WITHOUT losing anything else that was in it. Spike 0.4
# measured why the obvious implementations fail: Set-VMFirmware -BootOrder writes the
# whole order, so a subset write silently deleted this lab VM's own hard drive from
# its boot order (the order came back N=1), and a retry that re-inserts a device
# already in the order duplicates it. The contract these tests pin:
#
#   read the current order, compute the complete expected sequence, write it in ONE
#   Set-VMFirmware, read back the full ordered identity sequence, and on any mismatch
#   restore the captured original and raise — never leave a half-reordered VM;
#
# classification keys on the device class rendered from the entry's Device FIRST
# ("HardDiskDrive (...)", "VMNetworkAdapter (...)", "DvdDrive (...)") and falls
# back to BootType only when that rendering is empty, because a NIC entry answers
# BootType 'Network' — BootType-first never matched a requested VMNetworkAdapter,
# double-listed the adapter, and the host refused (PR-1 lab measurement); a File
# entry has a null Device and needs the BootType fallback so it is not dropped; and
# move-if-present matches the requested device by Id against the entry's Device.Id,
# never by object reference, because a freshly fetched device object never
# reference-equals the Device inside a boot entry (that is how a retry duplicates).
class UnitBootOrderTest < Minitest::Test
  # The OfflineClient shape FOG-11 established: connect dials nothing and
  # run_cmdlist is recorded. The script's JSON answer is set per test because the
  # requests' return contract is built on it.
  class RecordingClient < Fog::Hyperv::Compute::Real
    attr_reader :list_calls
    attr_accessor :verdict

    def initialize(options)
      @list_calls = []
      @verdict = '[]'
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
  DVD_ID = 'Microsoft:416E49FD-28DD-413C-9743-AA3E69E4807D\\33972D26-7EE4-49E8-8C11-C5F761133946\\0\\1\\D'

  ORDER_JSON = '[{"Position":1,"BootType":"Drive","DeviceText":"HardDiskDrive ' \
               '(Name = disk.vhdx)","DeviceId":"Microsoft:FAKE\\\\0\\\\0\\\\0","FirmwarePath":""}]'

  def setup
    @client = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  # The whole request is one batched call: commands rendered into one script.
  def script
    commands, = @client.list_calls.first
    commands.map { |command, _args| command }.join("\n")
  end

  def call_get
    @client.get_vm_boot_order(vm_id: VM_ID, computer_name: 'HV-NODE1')
  end

  def call_set(order: ['HardDiskDrive', { 'DvdDrive' => DVD_ID }, 'VMNetworkAdapter'])
    @client.set_vm_boot_order(vm_id: VM_ID, order: order, computer_name: 'HV-NODE1')
  end

  # --- the read ---------------------------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  def test_the_read_is_one_call_that_asks_the_firmware_and_answers_the_order
    @client.verdict = ORDER_JSON
    rows = call_get

    assert_equal 1, @client.list_calls.size
    assert_includes script, 'Get-VMFirmware'
    assert_equal 1, rows.size
    assert_equal 1, rows.first[:position]
    assert_equal 'HardDiskDrive (Name = disk.vhdx)', rows.first[:device_text],
                 'the Device rendering is the measured classification input, so the read has to carry it'
    assert_equal 'Microsoft:FAKE\\0\\0\\0', rows.first[:device_id]
  end
  # rubocop:enable Minitest/MultipleAssertions

  # --- the write: shape of the one script --------------------------------------

  def test_the_write_reads_computes_writes_and_verifies_in_one_call
    @client.verdict = ORDER_JSON
    call_set

    assert_equal 1, @client.list_calls.size,
                 'read, write and verify must share one script: separate calls leave windows ' \
                 'where another actor sees a half-reordered VM'
    assert_includes script, '-BootOrder'
    refute_includes script, '-FirstBootDevice',
                    'the measured spike says one -BootOrder write places even a freshly fetched ' \
                    'device object; -FirstBootDevice would be a second mutation of the same thing'
  end

  def test_classification_keys_on_the_device_rendering_with_boottype_only_as_fallback
    # F5 said a File entry has a null Device, so BootType must classify it — true.
    # The PR-1 lab measurement showed the other half: a NIC boot entry answers
    # BootType 'Network', and the only string carrying its class is the Device
    # rendering "VMNetworkAdapter (Name = ...)". Keying on BootType first left
    # that entry unconsumed, the fetch branch inserted the same adapter again,
    # and Set-VMFirmware refused the duplicate with WMI Element not found
    # (0x80070490) — twice on the real host, with both DVD spellings, which is
    # how it was caught. The rendering is the primary key; BootType classifies
    # only what renders empty.
    call_set

    assert_includes script, %q{$fogT = ("$($e.Device)" -split ' ')[0]},
                    'the device rendering is the primary classification key: it is the only string naming the class'
    assert_includes script, 'if ($fogT) { $fogT } else { "$($e.BootType)" }',
                    'BootType is the fallback for entries with no Device rendering (File entries), not the primary key'
  end

  def test_move_if_present_matches_the_requested_device_by_id_not_by_reference
    # F6: a device object fetched fresh never reference-equals the Device inside a
    # boot entry, so reference matching makes a retry insert a duplicate.
    call_set

    assert_includes script, '.Device.Id',
                    'presence must be decided by comparing the requested Id to each entry Device.Id'
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_the_requested_sequence_is_carried_in_the_requested_order
    call_set

    encoded = script[/ConvertFrom-Json -InputObject '([^']*)'/, 1]

    refute_nil encoded, 'the expected sequence rides into the script as JSON'

    parsed = Fog::JSON.decode(encoded.gsub("''", "'"))

    assert_equal %w[HardDiskDrive DvdDrive VMNetworkAdapter], parsed.map { |e| e['Class'] }
    assert_equal DVD_ID, parsed[1]['Id'], 'the DVD entry carries the drive Id the caller named'
    assert_nil parsed[0]['Id'], 'a class without a named Id moves the whole group'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_unrequested_entries_keep_their_positions_after_the_requested_ones
    # The measured loss: a subset write dropped this lab VM's hard drive out of its
    # boot order entirely. The script must append every entry it did not consume.
    call_set

    assert_includes script, '$fogTaken',
                    'entries consumed by the request are tracked so every other entry survives at the tail'
    assert_includes script, 'foreach ($fogE in $fogOrig)',
                    'the tail is built by walking the captured original order, in order'
  end

  def test_a_missing_named_dvd_drive_is_refused_not_written_around
    call_set

    assert_match(/DvdDrive.*throw|throw.*DVD/m, script,
                 'a DVD Id the VM does not have must refuse the request, not write an order missing it')
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_readback_mismatch_restores_the_captured_order_then_raises
    @client.verdict = ORDER_JSON
    call_set

    restore = script[/if \(\(\$fogGot.*\z/m]

    refute_nil restore, 'the read-back must be compared against what was written'
    assert_includes restore, 'Set-VMFirmware'
    assert_includes restore, '$fogOrig',
                    'the order written back must be the one captured before the write, not a guess'
    assert_includes restore, 'throw',
                    'and the caller has to learn the write did not take'
    assert_operator restore.index('Set-VMFirmware'), :<, restore.index('throw'),
                    'restore happens before the raise, not after'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_the_write_answers_the_new_order_it_read_back
    @client.verdict = ORDER_JSON
    rows = call_set

    assert_equal 1, rows.size
    assert_equal 'Drive', rows.first[:boot_type]
  end

  # --- refusals that need no traffic -------------------------------------------

  def test_unknown_classes_are_refused_before_any_call
    err = assert_raises(ArgumentError) { call_set(order: ['FloppyDrive']) }
    assert_match(/FloppyDrive/, err.message)
    assert_empty @client.list_calls, 'a refused request must not have reached the host'
  end

  def test_a_repeated_class_is_refused
    assert_raises(ArgumentError) { call_set(order: %w[HardDiskDrive HardDiskDrive]) }
    assert_empty @client.list_calls
  end

  def test_an_empty_order_is_refused
    assert_raises(ArgumentError) { call_set(order: []) }
    assert_empty @client.list_calls
  end

  def test_only_a_dvd_drive_may_be_named_by_id
    # HardDiskDrive/VMNetworkAdapter move as groups; naming one of them by Id asks
    # the request to drop the others of its class silently, which the group rule
    # forbids. DVD is the one class the seam drives through a specific drive Id.
    assert_raises(ArgumentError) { call_set(order: [{ 'HardDiskDrive' => 'some-id' }]) }
    assert_empty @client.list_calls
  end

  def test_order_entries_must_be_names_or_one_pair_hashes
    assert_raises(ArgumentError) { call_set(order: [%w[HardDiskDrive DvdDrive]]) }
    assert_raises(ArgumentError) { call_set(order: [{ 'DvdDrive' => DVD_ID, 'extra' => 1 }]) }
    assert_empty @client.list_calls
  end
end
