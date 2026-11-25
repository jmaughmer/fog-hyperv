# frozen_string_literal: true

require 'test_helper'

# One owner for "this text goes inside a PowerShell single-quoted literal".
# Two tokenizer facts make the naive escape wrong, and both were measured, not
# theorised:
#
#   1. PowerShell ends a single-quoted literal at the typographic quotes the
#      Unicode standard calls quotation marks — U+2018, U+2019, U+201A, U+201B
#      — exactly as it ends it at the ASCII apostrophe. Doubling only the ASCII
#      one (what this fork did at every site until now) lets a value like
#      a URL carrying U+2019 close its own literal and run the rest as code.
#   2. Inside a single-quoted literal NOTHING processes backslashes, and a JSON
#      encoder has already doubled the ones its output needs. Doubling them a
#      second time would corrupt the very paths and payloads this escape
#      carries, so this primitive deliberately leaves them alone.
#
# Every site that embeds into '...' now rides here: the pull script's URL and
# path, the boot-order request JSON, the role name filter, both path-cleanup
# scripts, the cmdlet option-map JSON, and the _by_id pipeline filter.
class UnitPsQuoteTest < Minitest::Test
  def subject
    Fog::Hyperv::Utils::PsQuote
  end

  def test_the_ascii_apostrophe_doubles
    assert_equal "O''Brien", subject.escape("O'Brien")
  end

  # The four Unicode single quotes the tokenizer treats as quote characters —
  # each one, doubled the same way. U+2018 LEFT, U+2019 RIGHT, U+201A SINGLE
  # LOW-9, U+201B SINGLE HIGH-REVERSED-9.
  def test_each_typographic_single_quote_doubles
    %W[\u2018 \u2019 \u201A \u201B].each do |quote|
      assert_equal "a#{quote}#{quote}b", subject.escape("a#{quote}b"),
                   "U+#{quote.codepoints.first.to_s(16).upcase} must double like the apostrophe does"
    end
  end

  def test_backslashes_pass_through_untouched
    # A single-quoted literal takes backslashes literally, and Windows paths
    # are the majority of what travels here. A "fix" that doubled them would
    # turn every path into a path to a different file.
    assert_equal 'C:\VMs\web 1.vhdx', subject.escape('C:\VMs\web 1.vhdx')
  end

  def test_text_with_no_quote_characters_is_returned_byte_for_byte
    plain = '{"Class":"DvdDrive","Id":"IDE (0,0)"}'
    assert_equal plain, subject.escape(plain)
  end

  def test_quote_wraps_the_escaped_body
    assert_equal "'a''b'", subject.quote("a'b")
    assert_equal "''", subject.quote('')
  end

  def test_a_non_string_is_refused_before_any_rendering
    [nil, 42, :sym, ['a list']].each do |bad|
      assert_raises(ArgumentError, "expected #{bad.inspect} to be refused") do
        subject.escape(bad)
      end
    end
  end

  def test_the_escape_is_idempotent_on_doubled_quotes
    # '' in, '''' out: doubling is per-character, so text that already carries
    # a doubled apostrophe becomes four — the literal then renders two. There
    # is no un-escaping here because no caller hands escaped text in; this
    # pins WHAT the primitive does rather than letting a future reader guess.
    assert_equal "a''''b", subject.escape("a''b")
  end
end
