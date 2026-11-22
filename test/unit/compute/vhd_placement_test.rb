# frozen_string_literal: true

require 'test_helper'

require 'logger'
require 'fog/hyperv/compute/models/server'
require 'fog/hyperv/compute/models/vhd'
require 'fog/hyperv/compute/models/host'

# FOG-17: the disk-placement join trusted both of its parts.
# build_vhd_path joined [computer.virtual_hard_disk_path, name, filename] and
# returned whatever came out — including the RELATIVE "web1\web1.vhdx" that
# happens when the host answers no disk root at all, which the WinRM shell
# resolves against its own working directory (measured C:\), landing the disk
# at C:\<name>\ no matter where the machine lives. And a machine built by
# servers.new carries no computer object until something resolves one, so the
# second shape was a bare NoMethodError on nil.
#
# The cluster layer needs more than correct-by-default: a clustered machine's
# disks must live on the shared volume its config was placed on, but fog gave
# the caller no way to say so — the node's disk root always answered, whether
# or not it was where the placement decision had put the machine. This suite
# adds the named placement folder (placement_path, honored absolutely and
# without asking the node), refuses every shape that would build a relative
# path, and gives the refusal a class of its own.
class UnitVhdPlacementTest < Minitest::Test
  # The service surface these models actually use: a hosts.get that answers
  # whatever the test loaded (including nothing), counted so a test can prove
  # an explicit placement never asked, and a new_vhd that records rather than
  # sends.
  class FakeCompute
    attr_reader :new_vhds, :host_lookups

    def initialize(host: nil)
      @host = host
      @new_vhds = []
      @host_lookups = 0
    end

    def hosts
      self
    end

    def get(_name)
      @host_lookups += 1
      @host
    end

    def new_vhd(**options)
      @new_vhds << options
      {}
    end

    def logger
      @logger ||= Logger.new(File::NULL)
    end
  end

  DISK_ROOT = 'C:\VMs\Disks'
  CONFIG_ROOT = 'C:\VMs'
  CSV_FOLDER = 'C:\ClusterStorage\Volume1\web1'
  ABSOLUTE = %r{\A(\w:[\\/]|[\\/]{2}\w+[\\/])}

  def host(disk_root: DISK_ROOT, config_root: CONFIG_ROOT)
    Fog::Hyperv::Compute::Host.new(service: @service, name: 'HV-NODE1',
                                   virtual_hard_disk_path: disk_root,
                                   virtual_machine_path: config_root)
  end

  def build_server(service, placement: :unset)
    server = Fog::Hyperv::Compute::Server.new(service: service,
                                              computer_name: 'HV-NODE1',
                                              name: 'web1')
    server.placement_path = placement unless placement == :unset
    server
  end

  def setup
    @service = FakeCompute.new(host: host)
  end

  # ---- the host-root default, kept -------------------------------------------

  def test_the_default_folder_is_still_the_host_disk_root_under_the_machine_name
    server = build_server(@service)

    path = server.build_vhd_path('web1.vhdx')

    assert_equal 'C:\\VMs\\Disks\\web1\\web1.vhdx', path
    assert_match ABSOLUTE, path
  end

  def test_the_config_path_default_is_still_the_host_config_root_under_the_machine_name
    server = build_server(@service)

    path = server.build_config_path('snapshots')

    assert_equal 'C:\\VMs\\web1\\snapshots', path
    assert_match ABSOLUTE, path
  end

  # ---- placement_path: the plugin's sentence, finally heard -------------------

  def test_placement_path_is_declared_not_swallowed
    assert_includes Fog::Hyperv::Compute::Server.attributes, :placement_path,
                    'the plugin sets vm.placement_path=; fog never declared it and the model ' \
                    'swallowed the assignment, building disks under the node root anyway'
  end

  def test_an_absolute_placement_folder_is_the_folder_the_vhd_lands_in
    server = build_server(@service, placement: CSV_FOLDER)

    path = server.build_vhd_path('web1.vhdx')

    assert_equal 'C:\\ClusterStorage\\Volume1\\web1\\web1.vhdx', path,
                 'the placement folder already names the machine folder — the name is not joined twice'
  end

  def test_an_explicit_placement_folder_needs_no_host_read_at_all
    server = build_server(@service, placement: CSV_FOLDER)

    server.build_vhd_path('web1.vhdx')

    assert_equal 0, @service.host_lookups,
                 'the caller that says where the disks go does not also have to be able to reach the host'
  end

  def test_placement_path_hands_the_absolute_folder_to_the_vhd_create
    server = build_server(@service, placement: CSV_FOLDER)
    vhd = Fog::Hyperv::Compute::Vhd.new(service: @service, vm: server,
                                        computer_name: 'HV-NODE1',
                                        basename: 'web1', size: 1_073_741_824)

    vhd.create

    assert_equal 1, @service.new_vhds.size
    assert_equal "#{CSV_FOLDER}\\web1.vhdx", @service.new_vhds.first[:path]
  end

  # ---- refuse, never build a relative path -------------------------------------

  def test_a_relative_placement_folder_is_refused_naming_itself
    server = build_server(@service, placement: 'Volume1\web1')

    error = assert_raises(Fog::Hyperv::Errors::InvalidPlacementPath) { server.build_vhd_path('web1.vhdx') }

    assert_includes error.message, 'Volume1'
    assert_includes error.message, 'relative folder'
  end

  def test_a_blank_placement_folder_is_no_placement_at_all
    server = build_server(@service, placement: '   ')

    path = server.build_vhd_path('web1.vhdx')

    assert_equal 'C:\\VMs\\Disks\\web1\\web1.vhdx', path,
                 'blank says nothing, so the host default answers — same rule the plugin reads back'
  end

  def test_a_host_answering_no_disk_root_is_refused_not_joined_into_a_relative_path
    service = FakeCompute.new(host: host(disk_root: nil))
    server = build_server(service)

    error = assert_raises(Fog::Hyperv::Errors::InvalidPlacementPath) { server.build_vhd_path('web1.vhdx') }

    assert_includes error.message, 'web1'
    assert_match(/disk/i, error.message, 'the refusal says which root is missing')
  end

  def test_a_host_that_cannot_be_resolved_is_a_refusal_not_a_no_method_error
    service = FakeCompute.new(host: nil)
    server = build_server(service)

    assert_raises(Fog::Hyperv::Errors::InvalidPlacementPath) { server.build_vhd_path('web1.vhdx') }
  end

  def test_a_host_answering_no_config_root_is_refused_not_joined_into_a_relative_path
    service = FakeCompute.new(host: host(config_root: nil))
    server = build_server(service)

    error = assert_raises(Fog::Hyperv::Errors::InvalidPlacementPath) { server.build_config_path(nil) }

    assert_match(/config/i, error.message)
  end

  def test_a_host_that_cannot_be_resolved_refuses_the_config_path_too
    service = FakeCompute.new(host: nil)
    server = build_server(service)

    assert_raises(Fog::Hyperv::Errors::InvalidPlacementPath) { server.build_config_path('snapshots') }
  end

  # ---- the create-time config join, same discipline -----------------------------

  def test_the_create_join_prepends_the_config_root_to_a_relative_path
    server = build_server(@service)

    joined = server.send(:join_config_root, 'sub\\dir')

    assert_equal 'C:\\VMs\\sub\\dir', joined
  end

  def test_the_create_join_leaves_an_absolute_path_alone
    server = build_server(@service)

    assert_equal CSV_FOLDER, server.send(:join_config_root, CSV_FOLDER)
    assert_equal 0, @service.host_lookups, 'an absolute path needs no root read'
  end

  def test_the_create_join_refuses_a_relative_path_when_the_host_names_no_config_root
    service = FakeCompute.new(host: nil)
    server = build_server(service)

    assert_raises(Fog::Hyperv::Errors::InvalidPlacementPath) { server.send(:join_config_root, 'sub\\dir') }
  end
end
