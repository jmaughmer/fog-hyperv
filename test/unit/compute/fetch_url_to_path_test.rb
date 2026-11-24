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
end
