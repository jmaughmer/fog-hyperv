# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/utils/contained_path'
require 'fog/hyperv/compute/requests/remove_file'

# FOG-21 (BD-1 fog PR-1, first commit): the bootdisk store hands fog a path the
# plugin built from a compute-resource setting plus a VM uuid, and asks for that
# one file to go away — repeatedly, because iso_delete runs on a built save that
# may already have been reaped. Two gaps had to close before that was safe.
#
# One: remove_item raises when the path is absent. It renders Remove-Item with
# -LiteralPath and no existence guard, and this transport turns any non-zero
# exit into Fog::Hyperv::Errors::PSError — measured on the lab host, where
# `Remove-Item -LiteralPath <missing> -ErrorAction SilentlyContinue` still
# raised. So "delete my ISO" fails on the second call, and the caller cannot
# tell "already gone" from "could not delete" without parsing text.
#
# Two: nothing in fog could say "this path must live inside that root". The
# root is an operator setting that reaches fog as a string, and a root of
# `C:\` — or an unset one — widens a delete to a whole volume.
#
# remove_file therefore checks existence in the same script that deletes, so
# there is no round-trip and no window, and it refuses, before any traffic,
# every path that cannot be honoured as one literal location inside an explicit
# root: drive-relative (`C:foo`, which resolves against the process's CWD),
# mixed separators (NTFS accepts `/` as a separator, so a containment check that
# only looked at `\` would be defeated by one), an embedded `..`, and the
# characters that stop a single-quoted literal from being one string — `$`
# inside double quotes, a backtick as the escape character, `;` and `|` as
# statement separators, and a quote.
class UnitRemoveFileTest < Minitest::Test
  # Fog::Hyperv::Compute::Real opens a WinRM connection on initialize; the
  # request under test only ever reaches run_cmdlist, so connect dials nothing
  # and run_cmdlist is recorded instead — the OfflineClient shape FOG-11
  # established, widened to the batch form the request actually uses.
  class RecordingClient < Fog::Hyperv::Compute::Real
    attr_reader :list_calls
    # What the removal script answers. The request's whole contract is built on
    # this line, so the tests that care about a particular answer set it here
    # rather than the client guessing one.
    attr_accessor :verdict

    def initialize(options)
      @list_calls = []
      @verdict = 'REMOVED=true'
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

  ROOT = 'C:\ClusterStorage\Volume1\foreman-bootdisk'

  def setup
    @client = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  def script
    commands, = @client.list_calls.first
    commands.first.first
  end

  def transport_options
    _commands, options = @client.list_calls.first
    options
  end

  def call(path: "#{ROOT}\\1\\1c51c4ee\\full-host.iso", root: ROOT, computer_name: 'HV-NODE1')
    @client.remove_file(path: path, root: root, computer_name: computer_name)
  end

  # --- the answer contract ---------------------------------------------------

  def test_one_call_carries_both_the_test_and_the_delete
    call

    assert_equal 1, @client.list_calls.size,
                 'existence and deletion must share one script: two calls leave a window and cost a round trip'
  end

  def test_deleting_a_file_that_was_there_answers_true
    answer = call

    assert_instance_of TrueClass, answer,
                       'the verdict is a boolean the caller branches on, not a string it greps: ' \
                       'true means a file was deleted'
    assert transport_options[:skip_json],
           'the verdict is a marker line, not a ConvertTo-Json payload'
  end

  def test_deleting_a_file_that_is_already_gone_answers_false_and_does_not_raise
    @client.verdict = 'REMOVED=false'

    assert_instance_of FalseClass, call,
                       'a repeated cleanup is the normal case: the file being gone is the request satisfied'
  end

  def test_an_answer_the_script_could_not_have_printed_raises
    @client.verdict = ''

    assert_raises Fog::Hyperv::Errors::RemovalVerdictUninterpretable do
      call
    end
  end

  # --- the delete itself -----------------------------------------------------

  def test_both_reads_use_literal_path
    call

    assert_match(/Test-Path -LiteralPath/, script)
    assert_match(/Remove-Item -LiteralPath/, script)
    # Every -Path that is not the Test-Path cmdlet name binds wildcards:
    # -LiteralPath has no dash before Path, so it cannot match this.
    refute_match(/(?<!Test)-Path/, script,
                 '-Path is wildcard semantics: one name can expand into a set')
  end

  def test_a_folder_is_refused_rather_than_deleted
    call

    assert_match(/PSIsContainer/, script)
    assert_match(/throw/, script)
    refute_match(/Remove-Item -LiteralPath \$fogPath -Force -Recurse/, script)
  end

  def test_no_silently_continue_hides_a_real_failure
    call

    # Absent is handled by the guard. Anything Remove-Item still fails on —
    # access denied, a file the guest holds open — must raise, not be swallowed
    # into a reported-fine deletion.
    refute_match(/-ErrorAction\s+SilentlyContinue/i, script)
  end

  def test_the_target_is_single_quoted_with_inner_quotes_doubled
    @client.remove_file(path: "C:\\bootdisk\\it's.iso", root: 'C:\bootdisk')

    assert_includes script, "'C:\\bootdisk\\it''s.iso'"
  end

  def test_the_target_computer_is_forwarded
    call(computer_name: 'HV-NODE2')

    assert_equal 'HV-NODE2', transport_options[:target_computer]
  end

  # --- containment: what gets refused before any traffic ---------------------

  def test_refuses_a_missing_root
    assert_refused 'C:\VMs\a.iso', nil
  end

  def test_refuses_an_empty_root
    assert_refused 'C:\VMs\a.iso', '   '
  end

  def test_refuses_a_relative_root
    assert_refused 'C:\VMs\bootdisk\a.iso', 'bootdisk'
  end

  def test_refuses_a_root_that_is_a_wildcard
    assert_refused 'C:\VMs\bootdisk\a.iso', 'C:\VMs\*'
  end

  def test_refuses_a_path_outside_the_root
    assert_refused 'C:\VMs\other\a.iso', ROOT
  end

  # "C:\ClusterStorage\Volume1\foreman-bootdisk-old\a.iso" starts with the root
  # as a string but is a different directory: prefix matching with no separator
  # boundary deletes outside the store.
  def test_refuses_a_sibling_directory_that_merely_starts_like_the_root
    assert_refused "#{ROOT}-old\\a.iso", ROOT
  end

  def test_refuses_a_drive_relative_path
    assert_refused 'C:foreman-bootdisk\a.iso', ROOT
  end

  def test_refuses_forward_slash_separators
    # NTFS honours '/' as a separator, so C:/Windows wins could satisfy a
    # backslash-only containment check while naming somewhere else entirely.
    assert_refused "#{ROOT}/sub/a.iso", ROOT
  end

  def test_refuses_an_embedded_traversal
    assert_refused "#{ROOT}\\..\\Windows\\a.iso", ROOT
  end

  def test_refuses_traversal_in_the_root
    assert_refused "#{ROOT}\\a.iso", "#{ROOT}\\.."
  end

  def test_refuses_wildcards
    assert_refused "#{ROOT}\\a?.iso", ROOT
    assert_refused "#{ROOT}\\web[12].iso", ROOT
  end

  def test_refuses_the_characters_that_break_a_quoted_literal
    ['$', '`', ';', '|', '<', '>', '"', "'", "\n"].each do |ch|
      next if ch == "'" # a quote is legal in an NTFS name and gets doubled

      assert_refused "#{ROOT}\\a#{ch}b.iso", ROOT
    end
  end

  def test_refuses_an_empty_or_non_string_path
    ['', '   ', ['C:\a.iso'], nil].each do |value|
      assert_refused value, ROOT
    end
  end

  # --- containment: what is honoured -----------------------------------------

  def test_accepts_a_path_inside_the_root
    @client.remove_file(path: "#{ROOT}\\1\\1c51c4ee\\full-host.iso", root: ROOT)

    assert_equal 1, @client.list_calls.size
  end

  def test_a_trailing_separator_on_the_root_does_not_change_the_answer
    @client.remove_file(path: "#{ROOT}\\a.iso", root: "#{ROOT}\\")

    assert_equal 1, @client.list_calls.size
  end

  # The root IS the volume on a single-node host, and that is a legitimate
  # store: containment must hold at the volume root and not mistake the drive
  # root for an unanchored path.
  def test_accepts_a_drive_root_as_the_root
    @client.remove_file(path: 'C:\foreman-bootdisk\a.iso', root: 'C:\\')

    assert_equal 1, @client.list_calls.size
  end

  def test_accepts_the_root_itself_as_the_target
    @client.remove_file(path: ROOT, root: ROOT)

    assert_equal 1, @client.list_calls.size
  end

  def test_accepts_a_cluster_shared_volume_path
    csv = 'C:\ClusterStorage\Volume1'
    @client.remove_file(path: "#{csv}\\foreman-bootdisk\\1\\uuid\\disk.iso", root: csv)

    assert_equal 1, @client.list_calls.size
  end

  def test_a_refusal_makes_no_call_at_all
    begin
      call(path: 'D:\elsewhere\a.iso')
    rescue Fog::Hyperv::Errors::InvalidDestructivePath
      nil
    end

    assert_empty @client.list_calls
  end

  # The name is quoted once and every cmdlet in the script reads the variable: a
  # script that re-rendered the literal could ask three cmdlets about three
  # different files if the quoting ever disagreed with itself.
  def test_the_name_is_quoted_once_and_reused
    call

    assert_equal 1, script.scan("$fogPath = '").size
    assert_equal 3, script.scan('-LiteralPath $fogPath').size,
                 'Test-Path, Get-Item and Remove-Item all bind the same variable'
  end

  # Fog's capability list is what the plugin gates new behaviour on — a name
  # here is an interface, not a note.
  def test_the_capability_is_advertised
    assert_includes Fog::Hyperv::CAPABILITIES, :contained_file_removal
  end

  private

  def assert_refused(path, root)
    @client.remove_file(path: path, root: root)

    flunk "expected #{path.inspect} under root #{root.inspect} to be refused"
  rescue Fog::Hyperv::Errors::InvalidDestructivePath => e
    refute_empty e.message, 'a refusal has to say what it refused'
  end
end
