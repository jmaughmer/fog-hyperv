# frozen_string_literal: true

require 'test_helper'

# Measured on the lab cluster: Add-ClusterVirtualMachineRole SUCCEEDED — group
# created, VM intact — and fog raised Fog::JSON::DecodeError: unexpected
# character: 'Warning:' at line 1 column 1. Failover-clustering cmdlets write
# their remote-execution advisory as a Warning record, PowerShell renders the
# warning/verbose/debug/information streams onto the shell's stdout, and
# run_cmdlist parses stdout as the JSON payload. Stop-ClusterNode was measured
# rendering roughly 29 such lines in one call. The contract these tests pin: a
# rendered cmdlet call merges those four streams into its success stream —
# Windows PowerShell 5.1 (measured on the lab node) rejects `cmd 3>&2` as a
# parse error, and that parse error even exits 0, so n>&2 is not an option —
# and a router immediately behind the call recognises the record types and
# hands them to the host's error channel, which was measured to arrive on
# WinRM stderr without producing an error record. Expressions and raw scripts
# are left exactly as they were, and a cmdlet call's stdout carries nothing
# but the payload.
class UnitStdoutHygieneTest < Minitest::Test
  # Records the exact strings that would go down the wire and answers a fixed
  # JSON body so the parse path stays exercised. The $? probe answers like a
  # shell whose last statement succeeded.
  class RecordingShell
    attr_reader :runs

    def initialize(stdout:, stderr: '')
      @runs = []
      @stdout = stdout
      @stderr = stderr
    end

    def run(script)
      @runs << script
      return Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('True', '', 0) if script == '$?'

      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(@stdout, @stderr, 0)
    end
  end

  # Stands in for the WinRM::Connection run_cmdlist shells on: connect() is
  # replaced below the way the exact-host tests replace it, so nothing dials.
  # The cache scan reads the endpoint out of @connection_opts, so it rides here
  # the way the gem's own connection carries it.
  class RecordingConnection
    def initialize(endpoint, shell)
      @shell = shell
      @connection_opts = { endpoint: endpoint }
    end

    def shell(_kind)
      yield @shell
    end
  end

  class OfflineClient < Fog::Hyperv::Compute::Real
    attr_reader :recording_shell

    def initialize(options)
      @recording_shell = RecordingShell.new(stdout: '{"Name":"HV-NODE1"}')
      super
    end

    private

    def connect(endpoint = nil)
      endpoint ||= @hyperv_endpoint
      conn = RecordingConnection.new(endpoint, @recording_shell)
      @connections[URI.parse(endpoint).host] = conn
      if endpoint == @hyperv_endpoint
        @connection = conn
        @connections['.'] = conn
        @connections['localhost'] = conn
      end
      conn
    end

    def discover_host_names(_fqdn)
      [nil, nil]
    end

    # build_pscall asks the machine's PowerShell major version once and caches
    # it; answered here so the recorder holds exactly the runs the tests asked
    # for, and the render assertions read what they mean.
    def ps_version
      { major: 5, minor: 1 }
    end
  end

  ROUTER = Fog::Hyperv::Utils::Winrm::ADVISORY_ROUTER

  def setup
    @client = OfflineClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
    @shell = @client.recording_shell
  end

  # The exact rendered shape: splat, stream merges, the router, then the JSON
  # pipe — the advisories are pulled out of the stream before ConvertTo-Json
  # ever sees them, which is what keeps the payload the only thing on stdout.
  def test_the_cmdlet_call_merges_the_noise_streams_into_a_router
    @client.run_cmd('Get-VMHardDiskDrive', vmname: 'web1')

    assert_equal 1, @shell.runs.size
    assert_match(/Get-VMHardDiskDrive @\S+ 3>&1 4>&1 5>&1 6>&1/, @shell.runs.first)
    assert_match(/ 3>&1 4>&1 5>&1 6>&1 \| #{Regexp.escape(ROUTER)} \| ConvertTo-Json/, @shell.runs.first)
  end

  # The payload lives on the success stream: it must never be merged, and
  # nothing may target stream 2 — 5.1 (measured) answers any n>&2 with the
  # "reserved for future use" parse error that then silently exits 0.
  def test_the_success_stream_is_never_merged_and_nothing_targets_the_error_stream
    @client.run_cmd('Get-VMHardDiskDrive', vmname: 'web1')

    @shell.runs.each do |script|
      script.lines.each do |line|
        refute_match(/(^|\s)1>&/, line)
        refute_match(/&2/, line)
      end
    end
  end

  # The router recognises exactly the four advisory record types — all four
  # measured on the lab node arriving under n>&1 with those names — and hands
  # them to the host's error channel, which produces no error record.
  def test_the_router_names_the_four_advisory_types_and_the_host_error_channel
    expected = %w[Warning Verbose Debug Information].map do |kind|
      "System.Management.Automation.#{kind}Record"
    end

    assert_includes ROUTER, '$Host.UI.WriteErrorLine'
    assert_empty expected.reject { |type| ROUTER.include?(type) }
  end

  # The version and discovery probes are expressions, not command invocations
  # carrying cmdlet advisories — they must render untouched. (Whitespace-
  # flexible: build_call leaves a double space where an empty @Args splat was
  # stripped — that is the base render, and this test is about what is NOT
  # added to it.)
  def test_expressions_render_exactly_as_they_used_to
    @client.run_cmd('$PSVersionTable.PSVersion', _ps_version: 1)

    assert_match(/\$PSVersionTable\.PSVersion\s+\| ConvertTo-Json/, @shell.runs.first)
    refute_includes @shell.runs.first, '3>&1'
    refute_includes @shell.runs.first, 'ForEach-Object'
  end

  # A raw script is a script: the boundary of this fix is the cmdlet call, and
  # claiming to clean raw scripts would be a false advertisement. It renders
  # as it always did.
  def test_raw_scripts_render_exactly_as_they_used_to
    @client.run_cmdlist([['$x = 1; Get-VM $x', {}]], skip_json: true)

    refute_includes @shell.runs.first, '3>&1'
    assert_includes @shell.runs.first, '$x = 1; Get-VM $x'
  end

  # separate_calls is documented on run_cmdlist but its per-call pscalls are
  # Arrays, which the first method call on the loop variable used to receive:
  # the runs now join and reach the shell intact, each still merged-and-routed.
  def test_separate_calls_reach_the_shell_intact_and_routed
    @client.run_cmdlist([['Get-VM', {}], ['Get-VHD', {}]], separate_calls: true, skip_json: true)

    assert_equal 2, @shell.runs.size
    assert_match(/Get-VM\s+3>&1 4>&1 5>&1 6>&1 \| #{Regexp.escape(ROUTER)}/, @shell.runs[0])
    assert_match(/Get-VHD\s+3>&1 4>&1 5>&1 6>&1 \| #{Regexp.escape(ROUTER)}/, @shell.runs[1])
  end

  # The session settings keep riding the first run at session scope, and every
  # run's script starts after them.
  def test_the_session_settings_still_ride_the_first_run
    @client.run_cmd('Get-VMHardDiskDrive', vmname: 'web1')

    assert @shell.runs.first.start_with?("#{Fog::Hyperv::Utils::Winrm::SHELL_SETTINGS}; ")
  end

  # The retry probe reads $? at session scope — it is a probe, not a cmdlet
  # call, and goes to the shell alone. (The router itself leaves $? untouched
  # when it routes an advisory — measured on the node — so this probe cannot
  # fire on advisories any more.)
  def test_the_success_retry_run_stays_bare
    @shell.instance_variable_set(:@stderr, 'FullyQualifiedErrorId : boom')

    assert @client.run_cmd('Get-VM', name: 'web1')
    assert_equal '$?', @shell.runs.last
  end

  # The payload reaching the parse path decodes — the live lab rows prove the
  # remote now renders a warning-emitting cmdlet call as payload-only stdout
  # with the advisory on stderr.
  def test_the_parsed_reply_is_the_payload_not_the_shell_chatter
    reply = @client.run_cmd('Get-VM', name: 'web1')

    assert_equal({ name: 'HV-NODE1' }, reply)
  end
end
