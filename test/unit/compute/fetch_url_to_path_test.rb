# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/utils/file_pull'
require 'fog/hyperv/compute/requests/fetch_url_to_path'

# FOG-21 (BD-1 fog PR-1): the Hyper-V host pulls the built ISO over HTTP instead
# of receiving it base64-pushed through WinRM — spike 0.1 measured the push at
# 0.54-0.75 MB/s (5.2-7.2 min per host, with a 16 MB chunk faulting in
# pwrshplugin.dll) against 148.9 MB/s for the host pulling the same file (1.6 s).
# Pulling moves the trust problem: the WinRM channel was authenticated, the HTTP
# pull is anonymous, so the CHECKS move onto the pull itself, and the round-10
# review pinned the order they run in (F3):
#
#   status 200 first — a 3xx body must not be trusted to throw on its own;
#   then size, then host-side sha256 — all while the file is still .part;
#   only then Move-Item to the final name.
#
# so a truncated or redirected body never wears the name the caller will mount.
# The $ProgressPreference line is its own measurement: PowerShell 5.1's progress
# bar measurably throttles downloads, and this script exists to be fast.
class UnitFetchUrlToPathTest < Minitest::Test
  # The OfflineClient shape FOG-11 established: connect dials nothing and
  # run_cmdlist records — which is also what run_cmd funnels into.
  class RecordingClient < Fog::Hyperv::Compute::Real
    attr_reader :list_calls
    attr_accessor :verdict

    def initialize(options)
      @list_calls = []
      @verdict = 'PULLED=245'
      super
    end

    private

    def connect(_endpoint = nil)
      @connection = Struct.new(:logger).new(Struct.new(:level).new(nil))
    end

    def run_cmdlist(commands, **options)
      @list_calls << [commands, options]
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(@verdict, '', 0)
    end
  end

  DEST = 'C:\ClusterStorage\Volume1\foreman-bootdisk\6\1c51c4ee\full-host.iso'
  URL = 'http://katello-sandbox.maughmer.net/bootdisk-pull/1c51c4ee000000000000000000000000.iso'
  SHA = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

  def setup
    @client = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  def call_fetch(url: URL, path: DEST, sha256: SHA, size: 245, computer_name: 'HV-NODE2')
    @client.fetch_url_to_path(url: url, path: path, sha256: sha256, size: size, computer_name: computer_name)
  end

  def script
    commands, = @client.list_calls.first
    commands.map { |command, _args| command }.join("\n")
  end

  def index_of(needle)
    position = script.index(needle)

    refute_nil position, "expected the script to contain #{needle.inspect}"
    position
  end

  # --- the order of the guards (round 10's F3, in order) -----------------------

  # rubocop:disable Minitest/MultipleAssertions
  def test_the_progress_bar_is_off_before_the_pull_and_the_pull_is_basic_parsing
    call_fetch

    assert_operator index_of("$ProgressPreference = 'SilentlyContinue'"), :<, index_of('Invoke-WebRequest'),
                    'the PS 5.1 progress bar measurably throttles downloads'
    assert_includes script, '-UseBasicParsing'
    assert_includes script, '-MaximumRedirection 0'
    assert_includes script, '-PassThru'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # rubocop:disable Minitest/MultipleAssertions
  def test_the_pull_lands_on_a_part_name_and_nothing_moves_until_the_checks_pass
    call_fetch

    assert_operator index_of('-OutFile $fogPart'), :<, index_of('.StatusCode -ne 200'),
                    'the status question is asked first: a 3xx with -MaximumRedirection 0 is ' \
                    'not trusted to throw on its own'
    assert_operator index_of('.StatusCode -ne 200'), :<, index_of('Get-Item'),
                    'the size check sees the .part, not a file that already wears the final name'
    assert_operator index_of('Get-Item'), :<, index_of('Get-FileHash'),
                    'the host-side sha256 is the last gate before the name changes'
    assert_operator index_of('Get-FileHash'), :<, index_of('Move-Item'),
                    'the rename is the reward for passing every check'
    assert_includes script, "#{DEST}.part",
                    'the part name is the final name plus .part — same directory, one rename away'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # rubocop:disable Minitest/MultipleAssertions
  def test_a_failing_check_removes_the_part_and_reraises
    call_fetch

    failure = script[/catch \{.*\}/m]

    refute_nil failure, 'every failure path must run through one cleanup'
    assert_includes failure, 'Remove-Item'
    assert_includes failure, '$fogPart'
    assert_includes failure, 'throw', 'and the caller learns which check said no'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_the_rename_is_forced_so_a_retry_replaces_a_stale_final_file
    call_fetch

    move = script[/Move-Item[^\n]*/]

    assert_includes move, '-Force'
    assert_includes move, "-Destination '#{DEST}'"
  end

  # --- what travels, and where it is quoted ------------------------------------

  def test_the_expected_size_and_hash_travel_into_the_script_verbatim
    call_fetch

    assert_includes script, '-ne 245', 'the expected size is compared while the file is still the part'
    assert_includes script, SHA.upcase, 'Get-FileHash answers uppercase; the expectation rides there too'
  end

  def test_a_single_quote_in_the_url_is_doubled_for_the_script
    call_fetch(url: "http://host/a'b.iso")

    assert_includes script, "a''b.iso", 'one un-doubled quote would end the PS string early'
  end

  # --- the verdict ---------------------------------------------------------------

  def test_the_answer_is_the_pulled_byte_count
    assert_equal 245, call_fetch
  end

  def test_a_body_the_script_could_not_have_printed_is_not_read_as_success
    @client.verdict = 'PULLED=abc'

    assert_raises(Fog::Hyperv::Errors::PullVerdictUninterpretable) { call_fetch }
  end

  # --- refusals that need no traffic ---------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  def test_paths_that_are_not_one_literal_location_are_refused_before_any_call
    # The same refusers remove_file already answers with, reused whole: one
    # literal absolute location, no wildcard, no traversal (InvalidDestructivePath
    # is that answer's name in this fork).
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) { call_fetch(path: 'relative\\full-host.iso') }
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) { call_fetch(path: 'C:drive-relative.iso') }
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) { call_fetch(path: "#{DEST}*.iso") }
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) { call_fetch(path: 'C:\store\..\escape.iso') }

    assert_empty @client.list_calls, 'a refused pull must not have reached the host'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # rubocop:disable Minitest/MultipleAssertions
  def test_url_sha256_and_size_are_validated_before_any_call
    assert_raises(ArgumentError) { call_fetch(url: 'ftp://host/x.iso') }
    assert_raises(ArgumentError) { call_fetch(sha256: 'deadbeef') }
    assert_raises(ArgumentError) { call_fetch(size: 0) }
    assert_raises(ArgumentError) { call_fetch(size: 'lots') }

    assert_empty @client.list_calls
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_an_option_the_request_never_reads_raises_at_the_call
    # The signature names the five inputs the script reads and nothing else.
    # A catch-all there swallows a typo'd keyword — computer_nmae: would have
    # pulled the ISO on the DEFAULT endpoint while the caller believed it had
    # named a host — so an option nobody reads is refused at the call as the
    # caller error it is, rather than silently dropped before any traffic.
    assert_raises(ArgumentError) do
      @client.fetch_url_to_path(url: URL, path: DEST, sha256: SHA, size: 245, computer_nmae: 'HV-NODE2')
    end

    assert_empty @client.list_calls, 'refused at the signature, no traffic'
  end

  # --- the operation window this one call rides (FOG-35) -------------------------

  # The WinRM operation timeout is a PER-CONNECTION setting (the gem answers 60 s
  # when nobody configures it; this fork's plugin pins 90), and the whole pull
  # script — download, size check, sha256 — must finish inside it. The whole-fork
  # review of 2026-11-26 measured the consequence for the bootdisk ride: a fixed
  # window caps the transfer at ~90 s x link throughput, and the abort bypasses
  # the script's own .part cleanup. This request already carries `size:`, so it
  # is the one that can compute the window: one MiB/s of budget, clamped to
  # [90, 3600] seconds, and never below the operation timeout the client itself
  # was configured with — the window this call adds can widen, never narrow.

  def last_options
    @client.list_calls.last.last
  end

  def window_for(size, client = @client)
    client.fetch_url_to_path(url: URL, path: DEST, sha256: SHA, size: size, computer_name: 'HV-NODE2')
    client.list_calls.last.last[:operation_timeout]
  end

  def test_the_pull_window_scales_with_the_size_it_carries
    assert_equal 90, window_for(245),
                 'a tiny file still rides the 90 s floor — scaling never shortens the window it replaced'

    # The measured full-host ISO: 245,366,784 bytes is 234.0 MiB, and at the
    # one-MiB/s budget the answer is 234 s — the review's arithmetic (245 MB
    # against a fixed 90 s needs ~2.8 MB/s) stops being a cliff.
    assert_equal 234, window_for(245_366_784), 'the measured ISO gets its seconds at 1 MiB/s, not a fixed 90'

    assert_equal 3_600, window_for(10 * (1024**3)), 'and the scaling is capped: no computed window runs past an hour'
  end

  def test_the_window_never_lowers_a_configured_operation_timeout
    pinned = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman', hyperv_operation_timeout: 120)

    assert_equal 120, window_for(245, pinned),
                 'an operator-pinned 120 beats the 90 floor: this call may widen the window, never narrow it'
    assert_equal 234, window_for(245_366_784, pinned),
                 'and the scaled window beats a SMALLER configured value for the big ride — max, not override'

    wide = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman', hyperv_operation_timeout: 7_200)

    assert_equal 7_200, window_for(245_366_784, wide),
                 'an explicit pin above the hour-cap is respected as-is: the cap bounds the COMPUTED window'
  end

  def test_the_window_rides_the_one_call_and_leaks_nothing_into_the_script
    call_fetch(size: 245_366_784)

    assert_equal 1, @client.list_calls.size, 'the window is an option on the pull, not an extra round trip'

    commands, = @client.list_calls.first
    _command, args = commands.first

    assert_empty args, 'the meta-argument is consumed by the plumbing; the pscall args stay clean'
    assert_equal 234, last_options[:operation_timeout]
  end
end
