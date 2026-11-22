# frozen_string_literal: true

require 'test_helper'

class UnitWinrmSetupTest < Minitest::Test
  # Fog::Hyperv::Compute::Real opens a WinRM connection on initialize, and what is
  # under test here is only the script it sends down once it has one
  class OfflineClient < Fog::Hyperv::Compute::Real
    def connect(_endpoint = nil)
      nil
    end
  end

  # Records what the shell was asked to run, and answers the way a shell that
  # agrees with everything does
  class RecordingShell
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(cmd)
      @calls << cmd
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('{}', '', 0)
    end
  end

  class RecordingConnection
    def initialize(shell)
      @shell = shell
    end

    def shell(_session)
      yield @shell
    end
  end

  def setup
    shell = @shell = RecordingShell.new
    @client = OfflineClient.new(
      hyperv_endpoint: 'http://hyperv.example:5985/wsman',
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
    # The block runs on the client, so the recorder has to be captured here rather
    # than read off an instance variable of the test
    @client.define_singleton_method(:connection) { |_computer| RecordingConnection.new(shell) }
    @client.run_cmd('Get-VM', _skip_json: true)
    # The run that carried the command; the PowerShell version probe may have run
    # first, and it is not what these checks are about
    @script = @shell.calls.find { |call| call.include?('Get-VM') }
  end

  # A progress bar renders into the response over a shell, and the control
  # characters in the rendering make the reply impossible to parse, which arrives
  # as a transport error that says nothing about the call that caused it
  def test_progress_rendering_is_turned_off_before_anything_is_asked
    assert_includes @script, "$ProgressPreference = 'SilentlyContinue'"
  end

  def test_the_shell_still_asks_no_questions_and_stops_at_the_first_error
    assert_includes @script, "$ConfirmPreference = 'None'"
    assert_includes @script, "$ErrorActionPreference = 'Stop'"
  end

  # Every shell.run is a command and a receive on the wire, so a settings call of
  # its own is a paid round trip before the asked-for call pays its own; the
  # settings ride in the front of the first one instead, ahead of the command
  # that needs them, and the shell keeps them for every run after. (Recording is
  # also the first run to build a call, which pays for the memoized PowerShell
  # version probe - that run is allowed; a run that is only settings is not.)
  def test_the_settings_ride_in_the_first_call_ahead_of_the_command
    settings_only = @shell.calls.reject { |call| call.include?('Get-VM') || call.include?('PSVersionTable') }
    assert_empty settings_only, 'the settings must not cost a round trip of their own'

    call = @shell.calls.find { |c| c.include?('Get-VM') }
    assert_includes call, "$ProgressPreference = 'SilentlyContinue'"
    assert call.index('ProgressPreference') < call.index('Get-VM'),
           'the settings have to be applied before the command that depends on them'
  end
end
