# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/models/vhd'

# FOG-14: the VHD destroy path carried two failure modes at once. It asked for
# the file plus a "#{path}.*" sibling glob — Remove-Item wildcard semantics —
# and it deleted the whole machine folder whenever a Test-Path said there was
# nothing in it, which is also what Test-Path says when it is refused access or
# the volume is unreadable. Both arms had to become refuse-unless-provable: one
# literal file, and a folder removed only on the strength of a successful
# enumeration that found nothing.
class UnitVhdDestroyTest < Minitest::Test
  # Stands in for the compute service with the two calls this model makes,
  # recorded rather than sent; the minitest the RPM set ships is too old for
  # Object#stub to forward keyword arguments, and the arguments are the point.
  class FakeCompute
    attr_reader :removed, :cmdlists

    def initialize
      @removed = []
      @cmdlists = []
    end

    def remove_item(**options)
      @removed << options
      true
    end

    def run_cmdlist(commands, **options)
      @cmdlists << [commands, options]
      true
    end
  end

  VHD_PATH = 'C:\ClusterStorage\Volume1\web1\web1.vhdx'

  def build_vhd(path: VHD_PATH, vm_name: 'web1', computer_name: 'HV-NODE1')
    @service = FakeCompute.new
    Fog::Hyperv::Compute::Vhd.new(
      service: @service,
      vm: Struct.new(:name).new(vm_name),
      path: path,
      computer_name: computer_name
    )
  end

  # The glob was the sibling-deletion mechanism: web[12].vhdx.* reached through
  # -Path was a character class, not a file list. One literal path now, or
  # nothing.
  def test_destroy_sends_exactly_one_removal_of_the_exact_file
    vhd = build_vhd(vm_name: 'not-the-folder')

    assert vhd.destroy
    assert_equal 1, @service.removed.size
    assert_equal VHD_PATH, @service.removed.first[:path]
  end

  def test_destroy_sends_no_glob_and_no_list
    build_vhd(vm_name: 'not-the-folder').destroy

    options = @service.removed.first

    assert_kind_of String, options[:path]
    refute_includes options[:path], '*'
  end

  # The folder arm used to run Test-Path root\* — a wildcard test whose $false
  # answer, including its access-denied answer, licensed Remove-Item -Recurse
  # -Force. The enumeration and its literal delete replace both halves.
  def test_folder_cleanup_replaces_the_test_path_with_an_enumeration
    script = folder_script

    assert_includes script, "Get-ChildItem -LiteralPath 'C:\\ClusterStorage\\Volume1\\web1'"
    refute_includes script, 'Test-Path'
    refute_includes script, '-Recurse'
  end

  # The delete is licensed by the count alone: zero found, then remove; and it
  # rides to the node exactly once, un-parsed, as a json-free call.
  def test_folder_cleanup_is_licensed_by_the_count_and_rides_once
    build_vhd.destroy

    commands, options = @service.cmdlists.first

    assert_equal 1, commands.size
    assert_includes commands.first.first, "Remove-Item -LiteralPath 'C:\\ClusterStorage\\Volume1\\web1'"
    assert_equal({ skip_json: true, target_computer: 'HV-NODE1' }, options)
  end

  def folder_script
    build_vhd.destroy
    @service.cmdlists.first.first.first.first
  end

  # The parent-folder-equals-machine-name condition is the scope guard that
  # keeps this from ever reaching a folder that holds more than this machine:
  # it stays, and it still refuses on mismatch.
  def test_folder_is_left_alone_when_the_folder_is_not_the_machines
    build_vhd(vm_name: 'some-other-machine').destroy

    assert_empty @service.cmdlists
  end

  # A path this side cannot name exactly is a scope this side cannot bound:
  # refused before the file delete, not just before the folder one.
  def test_an_unprovable_path_is_refused_before_any_service_call
    vhd = build_vhd(path: 'C:\VMs\web[12]\disk.vhdx')

    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) { vhd.destroy }
    assert_empty @service.removed
    assert_empty @service.cmdlists
  end
end
