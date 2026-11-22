# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/models/hard_drive'

# FOG-14: hard_drive#destroy carried support_persistent_reservations — the
# attribute its own documentation comment describes as "set when multiple VMs
# share the same underlying disk" — and destroy ignored it. Asking for the
# underlying file deleted a disk another running machine is reading, on a host
# the caller may not even own the role of. The underlying delete now refuses
# unless the flag reads exactly false: true says someone else shares the disk,
# and nil says the sharing state was never read, which is not a proof.
class UnitHardDriveDestroyTest < Minitest::Test
  # Records the calls the destroy path makes, in order; the minitest the RPM
  # set ships is too old for Object#stub to forward keyword arguments, and the
  # arguments — and the ordering — are the point.
  class FakeCompute
    attr_reader :calls

    def initialize
      @calls = []
    end

    def remove_vm_hard_disk_drive(**options)
      @calls << [:detach, options]
      {}
    end

    def remove_item(**options)
      @calls << [:remove_item, options]
      true
    end

    def run_cmdlist(commands, **options)
      @calls << [:run_cmdlist, commands, options]
      true
    end
  end

  def build_hard_drive(underlying_flag: :absent, vhd: true)
    @service = FakeCompute.new
    attributes = {
      service: @service,
      id: '9A2F1D3E-1111-2222-3333-444455556666',
      vm_id: 'e8f37f42-2222-3333-4444-555566667777',
      computer_name: 'HV-NODE1',
      path: 'C:\ClusterStorage\Volume1\web1\disk1.vhdx'
    }
    attributes[:support_persistent_reservations] = underlying_flag unless underlying_flag == :absent
    if vhd
      attributes[:vhd] = Fog::Hyperv::Compute::Vhd.new(
        service: @service,
        vm: Struct.new(:name).new('some-other-machine'), # folder arm stays out
        path: attributes[:path],
        computer_name: 'HV-NODE1'
      )
    end
    Fog::Hyperv::Compute::HardDrive.new(attributes)
  end

  # nil is the dangerous value: the attribute is not typed, so a drive that was
  # never read through the property arrives nil, and "never read" must not read
  # as "not shared".
  def test_underlying_is_refused_when_the_flag_was_never_read
    hd = build_hard_drive

    error = assert_raises(Fog::Hyperv::Errors::SharedDiskDeleteRefused) { hd.destroy(underlying: true) }
    assert_includes error.message, 'support_persistent_reservations'
    assert_empty @service.calls, 'the refusal must precede every mutation'
  end

  def test_underlying_is_refused_when_the_flag_says_the_disk_is_shared
    hd = build_hard_drive(underlying_flag: true)

    assert_raises(Fog::Hyperv::Errors::SharedDiskDeleteRefused) { hd.destroy(underlying: true) }
    assert_empty @service.calls
  end

  # Detaching the drive from this machine's configuration destroys nothing on
  # disk, so it stays available with the flag unread — refusing it too would
  # push callers toward claiming false they did not measure.
  def test_detaching_without_the_underlying_file_still_works_with_the_flag_unread
    hd = build_hard_drive

    assert hd.destroy
    assert_equal [:detach], @service.calls.map(&:first)
  end

  # Exactly false is the proof, and with it the underlying delete runs — after
  # the detach, never before it.
  def test_underlying_runs_when_the_flag_reads_false
    hd = build_hard_drive(underlying_flag: false)

    assert hd.destroy(underlying: true)
    assert_equal %i[detach remove_item], @service.calls.map(&:first)
    _verb, options = @service.calls.last

    assert_equal 'C:\ClusterStorage\Volume1\web1\disk1.vhdx', options[:path]
  end

  # The typed declaration is a documentation claim; the behaviour that matters
  # is that an unread flag stays nil rather than being coerced to false —
  # false is the value that licenses the delete, and a never-read drive must
  # not arrive holding it.
  def test_an_unread_flag_stays_nil_and_not_false
    hd = build_hard_drive

    assert_nil hd.support_persistent_reservations
  end
end
