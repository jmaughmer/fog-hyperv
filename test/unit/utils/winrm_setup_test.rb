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
    @setup = @shell.calls.first
  end

  # A progress bar renders into the response over a shell, and the control
  # characters in the rendering make the reply impossible to parse, which arrives
  # as a transport error that says nothing about the call that caused it
  def test_progress_rendering_is_turned_off_before_anything_is_asked
    assert_includes @setup, "$ProgressPreference = 'SilentlyContinue'"
  end

  def test_the_shell_still_asks_no_questions_and_stops_at_the_first_error
    assert_includes @setup, "$ConfirmPreference = 'None'"
    assert_includes @setup, "$ErrorActionPreference = 'Stop'"
  end

  # The settings have to be applied by the very first call of the shell: the ones
  # after it are the commands that were asked for
  def test_the_settings_are_applied_before_the_command_that_needs_them
    assert_includes @setup, 'ProgressPreference'
    assert_equal 'Get-VM', @shell.calls.last.strip
  end
end
