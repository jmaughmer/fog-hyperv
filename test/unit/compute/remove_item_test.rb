# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/requests/remove_item'

# FOG-14: remove_item was the one request body with a TODO asking for input
# validation, a -Path render (PowerShell wildcard semantics), and no shape
# checks at all. It renders -LiteralPath now, and it refuses, before any wire
# traffic, every path whose deletion scope is not exactly one location.
class UnitRemoveItemTest < Minitest::Test
  # Fog::Hyperv::Compute::Real opens a WinRM connection on initialize; the
  # request under test only ever reaches run_cmd, so connect dials nothing and
  # run_cmd is recorded instead — the OfflineClient shape FOG-11 established.
  class RecordingClient < Fog::Hyperv::Compute::Real
    attr_reader :cmd_calls

    def initialize(options)
      @cmd_calls = []
      super
    end

    private

    def connect(_endpoint = nil)
      @connection = Struct.new(:logger).new(Struct.new(:level).new(nil))
    end

    def run_cmd(cmd, **opts)
      @cmd_calls << [cmd, opts]
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('', '', 0)
    end
  end

  def setup
    @client = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  # -Path is wildcard semantics: the name web[12] is legal on NTFS and a
  # character class to Remove-Item -Path, which then deletes web1 and web2 and
  # leaves web[12] standing. -LiteralPath removes the expansion entirely — and
  # the bracketed name itself is refused outright, which is its own test below.
  def test_the_path_is_sent_as_a_literal_path
    @client.remove_item(path: 'C:\VMs\web1\web1.vhdx', computer_name: 'HV-NODE1')

    assert_equal 1, @client.cmd_calls.size

    cmd, opts = @client.cmd_calls.first

    assert_equal 'Remove-Item', cmd
    assert_equal 'C:\VMs\web1\web1.vhdx', opts[:literal_path]
  end

  def test_the_wildcard_rendering_name_is_gone_from_the_arguments
    @client.remove_item(path: 'C:\VMs\web1\web1.vhdx', computer_name: 'HV-NODE1')

    _cmd, opts = @client.cmd_calls.first

    refute opts.key?(:path), 'the path must not reach the wire under its wildcard-rendering name'
  end

  # The literal_path key is what the optmap carries, and the splat binds it —
  # the whole point of the rename is what PowerShell receives. Case-insensitive
  # on purpose: build_optmap re-capitalises the JSON keys whole-word, so the
  # render reads "Literalpath", and parameter binding ignores case the way
  # PowerShell does. What must not appear is the old key standing alone.
  def test_the_rendered_call_binds_the_literal_path_parameter
    rendered = @client.send(:build_pscall, 'Remove-Item', literal_path: 'C:\VMs\web1', _ps_version: 5).join("\n")

    assert_includes rendered.upcase, '"LITERALPATH"'
    refute_includes rendered.upcase, '"PATH"'
  end

  def test_the_target_node_still_rides_as_the_meta_argument
    @client.remove_item(path: 'C:\VMs\web1.vhdx', computer_name: 'HV-NODE2', recurse: true)

    _cmd, opts = @client.cmd_calls.first

    assert_equal 'HV-NODE2', opts[:_target_computer]
    assert opts[:recurse]
  end

  # The old destroy sent [path, "#{path}.*"] through this request; that list is
  # the scope this refuses, so it has to fail here and not be honoured.
  def test_a_sibling_glob_is_refused_before_any_wire_traffic
    [
      ['C:\VMs\web1.vhdx', 'C:\VMs\web1.vhdx.*'],
      'C:\VMs\web*\disk.vhdx',
      'C:\VMs\web?.vhdx',
      'C:\VMs\web[12]\disk.vhdx',
      '',
      '   ',
      nil
    ].each do |value|
      assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
        @client.remove_item(path: value)
      end
    end

    assert_empty @client.cmd_calls
  end

  # The capability the plan freezes for this behaviour: present on every
  # instance of this build, with no probe — it is a property of this code.
  def test_the_build_advertises_the_capability
    assert_includes Fog::Hyperv::CAPABILITIES, :literal_path_destructive
    assert_predicate @client, :supports_literal_path_destructive?
  end
end
