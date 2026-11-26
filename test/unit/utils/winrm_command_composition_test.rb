# frozen_string_literal: true

require 'test_helper'

# The composer of every WinRM command (Utils::Winrm#build_pscall and the
# version fallback's hand-written script) embedded text where the line wanted
# a literal, in three spots, all measured at base:
#
#   1. the version fallback script ended its last statement with a quote it
#      never opened — `(Get-Item $VMMS).VersionInfo.ProductVersion"` — so the
#      fallback that exists to answer when the WQL version query CANNOT
#      answer arrived instead as a PowerShell parse error;
#   2. the _return_fields projection embedded its camelized field list as
#      bare words (Select Name,Id), so a field value carrying one of the five
#      quote characters closed its own bare word and one carrying a `;`
#      composed a second statement into the pipeline;
#   3. -Depth interpolated whatever object arrived, so a non-integer could
#      append a statement to the very pipeline meant to contain the output.
#
# The rule the fixes share: text that rides a composed command rides as a
# single-quoted literal (PsQuote, the one owner for that escape, already
# carrying the five-quote doubling) or as a rendered integer — never as bare
# syntax. What is NOT promised: the Select line's BYTES move for every
# existing caller (Name,Id becomes 'Name','Id'), because argument-mode bare
# words already parsed as exactly those strings — the parsed arguments are
# identical, and every field-less and depth-default render is untouched. The
# _from_json: false double-quoted option map and its dead shell_quoted arms
# are FOG-31's ground and stay exactly as FOG-23 left them. One step is
# unchanged around all of this: fields ride Fog::Hyperv.camelize first (that
# is the projection's own pre-existing step, base included), so the expected
# bytes below carry its capitalize as well as the escape.
class UnitWinrmCommandCompositionTest < Minitest::Test
  class OfflineClient < Fog::Hyperv::Compute::Real
    def connect(_endpoint = nil)
      nil
    end
  end

  def setup
    @client = OfflineClient.new(
      hyperv_endpoint: 'http://compose.invalid:5985/wsman',
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
  end

  # Keyword arguments ride through as keywords, NOT via *args: a hash
  # splatted at send() arrives as a positional argument on Ruby 3 (the real
  # run failed "wrong number of arguments (given 2, expected 1)" exactly
  # here), and build_pscall reads its meta-knobs only as keywords.
  def build(command, **options)
    @client.send(:build_pscall, command, **options).join("\n")
  end

  # --- 1. the version fallback script must parse -----------------------------

  # The client the fallback rides on: the WQL query that answers first dies,
  # and the hand-written script the rescue composes is recorded, not run.
  def version_client
    client = OfflineClient.new(
      hyperv_endpoint: 'http://compose.invalid:5985/wsman',
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
    client.define_singleton_method(:run_wql) do |*_args|
      raise Fog::Errors::Error, 'the WQL version query is the arm under test'
    end
    runs = @version_runs = []
    client.define_singleton_method(:run_cmd) do |command, **options|
      runs << [command, options]
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new("10.0.14393\r\n", '', 0)
    end
    client
  end

  def test_the_version_fallback_answers_and_asks_for_no_json_on_ps1
    # Shape pins that hold before and after: the fallback's answer is
    # stripped, and it still declares itself raw output on PowerShell 1, the
    # floor its probe must parse on. version is private on the mixin — the
    # same send the build_pscall pins above ride.
    assert_equal '10.0.14393', version_client.send(:version)
    _script, options = @version_runs.first

    assert options[:_skip_json]
    assert_equal 1, options[:_ps_version]
  end

  def test_the_version_fallback_script_closes_the_statement_it_opens
    version_client.send(:version)
    script = @version_runs.first.first

    line = script.lines.find { |l| l.include?('VersionInfo.ProductVersion') }

    refute_nil line, 'the fallback must still ask vmms.exe for its version'
    refute_includes line, '"',
                    'the recorded script ends the probe with a quote it never opens'
    assert_equal 0, script.scan('"').size % 2,
                 'every double quote the script opens it must close'
  end

  # --- 2. the Select list rides literals, not bare words ----------------------

  def test_the_select_list_ships_each_field_as_a_single_quoted_literal
    rendered = build('Get-VM', _return_fields: %i[name id], _ps_version: 5)

    assert_includes rendered, "Select 'Name','Id'"
  end

  def test_a_field_carrying_a_quote_closes_nothing_it_does_not_open
    # The field rides camelize first — the projection's own pre-existing step
    # (callers hand it attribute names, and capitalize is what makes an
    # attribute symbol render CamelCase). The literal's escape is what this
    # pins: the apostrophe doubled, nothing closing before it.
    rendered = build('Get-VM', _return_fields: ["o'brien"], _ps_version: 5)

    assert_includes rendered, "Select 'O''brien'"
  end

  def test_a_field_carrying_a_semicolon_stays_data
    # Hand-built expected bytes: camelize's capitalize rides the first
    # character (the rest of this lowercase field it leaves alone), the
    # typographic quote doubles, and the semicolon stays data inside the
    # literal. At base this field was worse than composition: the base log
    # shows it rendered bare as Select A’; ... — and PsQuote's own doctrine
    # is that a typographic quote opens a single-quoted literal, so base
    # shipped an opener nothing closed and the whole command arrived as an
    # unterminated-string parse error. The next test pins the quoted-free
    # field whose '; does compose a second statement.
    rendered = build('Get-VM', _return_fields: ["a\u2019; remove-item c:\\vms -recurse"], _ps_version: 5)

    assert_includes rendered, "Select 'A\u2019\u2019; remove-item c:\\vms -recurse'"
  end

  def test_a_field_carrying_a_bare_semicolon_composes_no_second_statement
    # The composition scenario with its quote characters removed: at base
    # this field rendered bare (Select Net; exit), and the ';' split the
    # pipeline — Select Net became the whole first statement and exit, then
    # ConvertTo-Json over nothing, the second. Inside the literal the ';'
    # is just data about a machine name that happens to contain one.
    rendered = build('Get-VM', _return_fields: ['net; exit'], _ps_version: 5)

    assert_includes rendered, "Select 'Net; exit'"
  end

  def test_a_call_that_names_no_fields_renders_no_select
    # The invisible-elsewhere pin: the literal only ever appears where a
    # projection was asked for.
    rendered = build('Get-VM', name: 'web1', _ps_version: 5)

    refute_includes rendered, 'Select'
  end

  # --- 3. -Depth renders an integer, whatever arrives -------------------------

  def test_the_depth_flag_renders_an_integer_however_it_arrives
    rendered = build('Get-VM', name: 'web1', _json_depth: '2; exit', _ps_version: 5)

    assert_includes rendered, '-Depth 2'
    refute_includes rendered, 'exit',
                    'a string depth composed a statement onto the pipeline'
  end

  def test_the_default_depth_still_renders_byte_for_byte
    rendered = build('Get-VM', name: 'web1', _ps_version: 5)

    assert_includes rendered, 'ConvertTo-Json -Compress -Depth 1'
  end
end
