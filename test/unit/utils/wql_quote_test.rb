# frozen_string_literal: true

require 'test_helper'

# One owner for "this value becomes a WQL literal". The grammar this
# primitive implements was MEASURED on HV-CL01 through this gem's own
# run_wql path (2026-11-26, parse acceptance on read-only SELECTs), not read
# out of a spec: the engine this gem dials — Microsoft WQL over WinRM —
# delimits string literals with DOUBLE QUOTES ONLY (a single-quoted literal,
# even WHERE Caption = 'Hosting Computer System', is refused: WSMan fault
# 2150858778 = WBEM_E_INVALID_QUERY), and inside them a backslash is the
# escape character: \\ is a literal backslash, \" a literal double quote,
# and backslash-before-anything-else is an invalid escape the engine
# refuses. The DMTF CQL grammar (DSP0202), which allows ' literals and
# knows no backslash escapes, is not the dialect on this wire.
#
# The pre-FOG-34 String#inspect shared the delimiter and the two escapes by
# coincidence of Ruby's grammar, but rewrites control characters into \t
# text and #{ into \#{ — invalid escapes here — and renders non-Strings
# unquoted. Those queries died at the provider; the owners below refuse
# before the wire instead.
#
# Unlike PowerShell, WQL ends a literal ONLY at the delimiter — the
# typographic-quote story belongs to PsQuote and the PowerShell tokenizer,
# and this primitive passes those characters through (measured parse OK).
class UnitWqlQuoteTest < Minitest::Test
  def subject
    Fog::Hyperv::Utils::WqlQuote
  end

  # --- the two escapes this engine honors ----------------------------------

  def test_the_double_quote_is_escaped
    assert_equal 'a\\"b', subject.escape('a"b')
    assert_equal '"a\\"b"', subject.quote('a"b')
  end

  # Backslashes are escaped FIRST, so the quote escape's own backslash is
  # never doubled behind it. Windows paths are the obvious carrier, and an
  # unescaped "C:\VMs" is a measured engine refusal (invalid \S escape).
  def test_backslashes_are_escaped_first
    assert_equal 'C:\\\\VMs', subject.escape('C:\\VMs')
    assert_equal '"C:\\\\VMs"', subject.quote('C:\\VMs')
  end

  # The collapse class, pinned: a value ending in one backslash would make
  # \' escape the closing delimiter and run the literal into the rest of the
  # WHERE clause (measured refusal: "trail\"). The escape makes it "trail\\".
  def test_a_trailing_backslash_cannot_eat_the_closing_delimiter
    quoted = subject.quote('trail\\')

    assert_equal '"trail\\\\"', quoted
    assert quoted.end_with?('\\"'), 'the closing delimiter must ride escaped-backslash-safe'
  end

  # Inside a double-quoted literal the apostrophe is plain content —
  # doubling it (the DMTF/CQL habit) would ask the engine for two of them.
  def test_the_apostrophe_is_plain_content
    assert_equal "it's", subject.escape("it's")
    assert_equal "\"it's\"", subject.quote("it's")
  end

  # The contrast with PsQuote, pinned so nobody "fixes" this file with the
  # PowerShell story: WQL has no Unicode literal terminators (measured OK).
  def test_typographic_quotes_pass_through
    %w[‘ ’ ‚ ‛].each do |quote|
      assert_equal "a#{quote}b", subject.escape("a#{quote}b"),
                   "U+#{quote.codepoints.first.to_s(16).upcase} is not a WQL delimiter"
    end
  end

  # --- the key position: enforced shape, not symbol faith --------------------

  def test_column_accepts_bare_property_names
    assert_equal 'ElementName', subject.column('ElementName')
    assert_equal 'Name', subject.column(:Name)
  end

  # A Symbol can carry ANY text — :"a OR 1=1" is a Symbol — so the key
  # position is guarded by shape. Anything that is not a bare
  # [A-Za-z][A-Za-z0-9_]* name is refused as structure, not hidden in it.
  def test_column_refuses_keys_carrying_structure
    ['a OR 1=1', "x' OR 'y'='y", 'A B', 'A(B)', '', '1x'].each do |key|
      assert_raises(ArgumentError, "#{key.inspect} is not a bare property name") do
        subject.column(key)
      end
    end
  end

  # --- refusals --------------------------------------------------------------

  # A raw control byte actually parses inside a measured literal, but no
  # legitimate comparison value carries one and refusal keeps every query a
  # readable single line in the debug log.
  def test_control_characters_are_refused_not_embedded
    ["a\nb", "a\tb", "a\u0000b", "a\u007Fb"].each do |value|
      assert_raises(ArgumentError, "control char U+#{value[1].codepoints.first.to_s(16).upcase} must be refused") do
        subject.escape(value)
      end
    end
  end

  def test_escape_refuses_non_strings
    [nil, :sym, 1, 1.5, true, Time.now, []].each do |value|
      assert_raises(ArgumentError, "#{value.class} has no inside-literal rendering") do
        subject.escape(value)
      end
    end
  end

  # --- whole-literal rendering ------------------------------------------------

  def test_text_rides_double_quoted
    assert_equal '"O\'Brien"', subject.literal("O'Brien")
  end

  # Measured here: the bare integer and TRUE/true/FALSE/false forms parse.
  # The bare -1, 1.5 and Float#to_s edge forms (NaN, 1.0e+16) were measured
  # as refusals at the provider — they ride as Float#to_s says, exactly as
  # at base, and the engine answers loudly, never as a wrong query.
  def test_numbers_ride_bare
    assert_equal '5', subject.literal(5)
    assert_equal '-1', subject.literal(-1)
    assert_equal '1.5', subject.literal(1.5)
  end

  def test_floats_ride_their_to_s_form
    assert_equal 'NaN', subject.literal(Float::NAN)
    assert_equal '1.0e+16', subject.literal(1e16)
  end

  def test_booleans_ride_bare
    assert_equal 'true', subject.literal(true)
    assert_equal 'false', subject.literal(false)
  end

  # A Time asked inspect's old to_s-with-spaces arm to quote its default
  # render — an unquoted multi-word clause ("WHERE Name = 2026-11-26
  # 12:00:00 +0000") the provider refuses. It is refused HERE now; the
  # caller renders the string it actually means.
  def test_values_without_a_wql_literal_rendering_are_refused
    [:sym, nil, Time.now, [], {}].each do |value|
      assert_raises(ArgumentError, "#{value.class} must be refused, not guessed at") do
        subject.literal(value)
      end
    end
  end
end
