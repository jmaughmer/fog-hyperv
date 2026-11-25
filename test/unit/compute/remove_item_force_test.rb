# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/requests/remove_item'

# Review F8: upstream's remove_item always sent force: true; the FOG-14
# -LiteralPath rewrite dropped it, and no caller passes it, so the dropped
# default was never re-added. Consequence measured against the review's
# scenario: the folder cleanup behind Server#destroy(true) recurses into the
# machine folder after Remove-VM has already succeeded, and one hidden or
# read-only item (a read-only parent .vhdx, a backup-agent flag) makes
# Remove-Item error — fog raises PSError with the VM gone and the folder
# left. -Force has no part in the wildcard question the rewrite was about.
class UnitRemoveItemForceTest < Minitest::Test
  # The remove_item_test.rb recording shape: the request only reaches
  # run_cmd, which is recorded instead of dialled.
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

  # The default: a plain call carries force — the parameter that survives
  # hidden and read-only items — alongside the literal path.
  def test_the_request_sends_force_by_default
    @client.remove_item(path: 'C:\VMs\web1\web1.vhdx', computer_name: 'HV-NODE1')

    assert_equal 1, @client.cmd_calls.size

    _cmd, opts = @client.cmd_calls.first

    assert opts[:force], 'the request must send force by default'
    assert_equal 'C:\VMs\web1\web1.vhdx', opts[:literal_path]
  end

  # destroy(true)'s real call shape — recurse rides and force rides WITH it.
  def test_the_recursive_destroy_cleanup_sends_force_too
    @client.remove_item(path: 'C:\ClusterStorage\Volume1\web1', computer_name: 'HV-NODE2', recurse: true)

    _cmd, opts = @client.cmd_calls.first

    assert opts[:force]
    assert opts[:recurse]
  end

  # Upstream's caller-override ordering is kept: force is a default written
  # BEFORE **options, so an explicit false still wins.
  def test_a_caller_can_still_turn_force_off
    @client.remove_item(path: 'C:\VMs\web1\web1.vhdx', force: false)

    _cmd, opts = @client.cmd_calls.first

    refute_equal false, opts[:force]
  end

  # What PowerShell actually binds: the rendered optmap JSON carries
  # Force:true next to the literal path — the whole point is the wire shape.
  def test_the_rendered_call_binds_the_force_parameter
    @client.remove_item(path: 'C:\VMs\web1')

    _cmd, opts = @client.cmd_calls.first

    rendered = @client.send(:build_pscall, 'Remove-Item',
                            **opts.reject { |k, _| k.to_s.start_with?('_') },
                            _ps_version: 5).join("\n")

    assert_includes rendered.upcase, '"FORCE":TRUE'
    assert_includes rendered.upcase, '"LITERALPATH"'
  end

  # The gate did not move: an invalid path still refuses before any wire
  # traffic, force default or not.
  def test_a_glob_path_is_still_refused_before_the_force_default_matters
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
      @client.remove_item(path: 'C:\VMs\*')
    end

    assert_empty @client.cmd_calls
  end
end
