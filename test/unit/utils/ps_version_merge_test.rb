# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/utils/winrm'

# Review F5: the stream merge rode every cmdlet call unconditionally, but the
# Information stream and its 6> redirect operator exist only from PowerShell
# 5.0. On an older host the appended 6>&1 is a PARSE ERROR for the whole
# rendered script — and this fork's own measurement of parse failures is exit
# 0, $? true, empty stdout — so every read answered empty and every write
# answered success. The merge and router are now version-gated: below 5 the
# call gets the 3/4/5 merges (valid since PowerShell 3) and a router naming
# only the three record types that exist there (InformationRecord would be an
# unresolvable type on PS 4: a runtime error per piped object, payload
# dropped). Expectations are hand-built bytes, never read from the lib
# constants, so each test states the wire shape on its own terms.
class UnitPsVersionMergeTest < Minitest::Test
  FULL_MERGE = ' 3>&1 4>&1 5>&1 6>&1'
  LEGACY_MERGE = ' 3>&1 4>&1 5>&1'
  FULL_ROUTER = 'ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord] ' \
                '-or $_ -is [System.Management.Automation.VerboseRecord] ' \
                '-or $_ -is [System.Management.Automation.DebugRecord] ' \
                '-or $_ -is [System.Management.Automation.InformationRecord]) ' \
                "{ $Host.UI.WriteErrorLine($_.GetType().Name.Replace('Record', '').ToUpper() + ': ' + $_.ToString()) } " \
                'else { $_ } }'
  LEGACY_ROUTER = 'ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord] ' \
                  '-or $_ -is [System.Management.Automation.VerboseRecord] ' \
                  '-or $_ -is [System.Management.Automation.DebugRecord]) ' \
                  "{ $Host.UI.WriteErrorLine($_.GetType().Name.Replace('Record', '').ToUpper() + ': ' + $_.ToString()) } " \
                  'else { $_ } }'

  # The stdout-hygiene harness shape, with the PROBED version dialable — the
  # gate's whole point is that it reads the endpoint's actual major.
  class RecordingShell
    attr_reader :runs

    def initialize
      @runs = []
    end

    def run(script)
      @runs << script
      return Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('True', '', 0) if script == '$?'

      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('{"Major":5,"Minor":1}', '', 0)
    end
  end

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
    attr_accessor :mock_ps_major

    def initialize(options)
      @recording_shell = RecordingShell.new
      @mock_ps_major = 5
      super
    end

    def ps_version
      { major: @mock_ps_major, minor: 1 }
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
      []
    end
  end

  def setup
    @client = OfflineClient.new(
      hyperv_username: 'u', hyperv_password: 'p', hyperv_basic_auth_user: 'u',
      hyperv_basic_auth_password: 'p', hyperv_endpoint: 'https://hyperv.lab/wsman'
    )
  end

  # The production path: the endpoint PROBED as PowerShell 4 must get a
  # render that parses there — no 6>&1 anywhere, and no InformationRecord
  # the PS 4 router could not resolve.
  def test_a_ps4_endpoint_gets_the_merge_that_parses_there
    @client.mock_ps_major = 4
    @client.run_cmd('Get-VM')

    script = @client.recording_shell.runs.first

    assert_includes script, "#{LEGACY_MERGE} | #{LEGACY_ROUTER} | ConvertTo-Json"

    refute_includes script, '6>&1'

    refute_includes script, 'InformationRecord'
  end

  # A caller dialling an older version explicitly gets the same legacy pair.
  def test_an_explicit_ps_version_below_five_takes_the_legacy_path
    @client.run_cmd('Get-VM', _ps_version: 1)

    script = @client.recording_shell.runs.first

    assert_includes script, "#{LEGACY_MERGE} | #{LEGACY_ROUTER} | ConvertTo-Json"

    refute_includes script, '6>&1'
  end

  # What a PS 5+ endpoint gets must be byte-for-byte the merge-and-router the
  # fork shipped, gates included — this pin protects the refactor that split
  # the router into shared fragments.
  def test_a_ps5_endpoint_renders_byte_for_byte_what_the_merge_shipped
    @client.run_cmd('Get-VM')

    script = @client.recording_shell.runs.first

    assert_includes script, "#{FULL_MERGE} | #{FULL_ROUTER} | ConvertTo-Json -Compress -Depth 1"
  end

  # The gate reads the probed major, not a constant: the same client object,
  # probed 5 then re-probed 4, flips its render.
  def test_the_probed_version_is_what_the_gate_reads
    @client.run_cmd('Get-VM')

    assert_includes @client.recording_shell.runs.last, FULL_ROUTER

    @client.mock_ps_major = 4
    @client.run_cmd('Get-VM')

    refute_includes @client.recording_shell.runs.last, '6>&1'
  end

  # The gate did not move the boundary: expressions and raw scripts render
  # bare at ANY version, exactly as they used to (the double space is the
  # base render of a stripped empty splat — what matters is what is NOT
  # added).
  def test_expressions_render_bare_at_ps4_too
    @client.run_cmd('$PSVersionTable.PSVersion', _ps_version: 4)

    script = @client.recording_shell.runs.first

    assert_match(/\$PSVersionTable\.PSVersion\s+\| ConvertTo-Json/, script)

    refute_includes script, '>&1'

    refute_includes script, 'ForEach-Object'
  end

  # separate_calls renders each call through the same gate — a PS 4 host
  # must not get the breaking redirect on ANY of them.
  def test_separate_calls_are_all_legacy_on_a_ps4_endpoint
    @client.mock_ps_major = 4
    @client.run_cmdlist([['Get-VM', {}], ['Get-VHD', {}]], separate_calls: true, skip_json: true)

    assert_equal 2, @client.recording_shell.runs.size
    @client.recording_shell.runs.each do |script|
      assert_includes script, "#{LEGACY_MERGE} | #{LEGACY_ROUTER}"

      refute_includes script, '6>&1'
    end
  end
end
