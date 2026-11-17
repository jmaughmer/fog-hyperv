# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/models/hard_drive'
require 'fog/hyperv/compute/models/vhd'

class UnitHardDriveVhdTest < Minitest::Test
  # A machine's VHD collection with Fog's contract kept honest: reading through
  # detect lazy-loads once and answers from memory after (which is what lets
  # the drives share one read), and getting a disk that is not there is a
  # NotFound rather than a nil.
  class CountingVhds
    attr_reader :list_calls, :get_calls

    def initialize(vhds, fail_list: false)
      @vhds = vhds
      @fail_list = fail_list
      @list_calls = 0
      @get_calls = 0
      @loaded = false
    end

    def detect(&block)
      lazy_load
      @vhds.detect(&block)
    end

    def get(path, **_filters)
      @get_calls += 1
      found = @vhds.detect { |vhd| vhd.path.casecmp?(path) }
      raise Fog::Errors::NotFound, "no vhd at #{path}" unless found

      found
    end

    private

    def lazy_load
      return if @loaded

      @list_calls += 1
      raise Fog::Hyperv::Errors::PSError.new(nil, 'Get-VHD choked on a broken disk') if @fail_list

      @loaded = true
    end
  end

  class FakeVm
    attr_reader :vhds, :name

    def initialize(vhds, name: 'fake-vm')
      @vhds = vhds
      @name = name
    end
  end

  class FakeService
    def logger
      @logger ||= Class.new { def debug(_); end }.new
    end
  end

  def vhd(path)
    Fog::Hyperv::Compute::Vhd.new(path: path)
  end

  def drive(vm, path)
    Fog::Hyperv::Compute::HardDrive.new(vm: vm, path: path, service: FakeService.new)
  end

  def machine(*paths, fail_list: false)
    FakeVm.new(CountingVhds.new(paths.map { |p| vhd(p) }, fail_list: fail_list))
  end

  # A VM with several drives used to pay one Get-VHD round trip per drive on
  # every listing that reads their details; one lazy load answers the whole
  # machine
  def test_the_drives_of_a_machine_share_one_read
    vm = machine('C:\\VMS\\a.vhdx', 'C:\\VMS\\b.vhdx')

    first = drive(vm, 'C:\\vms\\a.vhdx').vhd
    second = drive(vm, 'c:\\vms\\B.VHDX').vhd

    assert_equal 'C:\\VMS\\a.vhdx', first.path
    assert_equal 'C:\\VMS\\b.vhdx', second.path
    assert_equal 1, vm.vhds.list_calls, 'one read for every drive on the machine'
    assert_equal 0, vm.vhds.get_calls
  end

  # The list is a snapshot; a disk attached after it was read is not in it,
  # and that is exactly the case the single read still has to answer - NotFound
  # when even that misses, the way the getter has always answered a gone disk
  def test_a_disk_the_list_does_not_name_falls_back_to_the_single_read
    vm = machine('C:\\VMS\\a.vhdx')

    assert_raises(Fog::Errors::NotFound) do
      drive(vm, 'C:\\VMS\\attached-since.vhdx').vhd
    end
    assert_equal 1, vm.vhds.get_calls, 'the miss is checked the way it used to be'
  end

  # Get-VHD fails outright on a machine with one broken disk; the drive whose
  # own file is fine must not lose its answer to a listing that could not be had
  def test_a_machine_whose_list_fails_falls_back_to_the_single_read
    vm = machine('C:\\VMS\\a.vhdx', fail_list: true)

    assert_equal 'C:\\VMS\\a.vhdx', drive(vm, 'C:\\vms\\a.vhdx').vhd.path
    assert_equal 1, vm.vhds.list_calls
    assert_equal 1, vm.vhds.get_calls
  end
end
