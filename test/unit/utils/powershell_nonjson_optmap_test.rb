# frozen_string_literal: true

require 'test_helper'

# The _from_json: false option map — the one non-JSON arm of build_optmap —
# was first EXECUTED by FOG-23's render test, and that execution only ever
# reached the arm's first line. Below it, shell_quote's Array arm and its
# non-scalar fallback called shell_quoted — the utils rewrite (e6a1410)
# moved this quoting into this file, deleted shell_quoted's definition, and
# left the two calls behind (round-24 F1): an Array or Integer
# option died with a NoMethodError for shell_quoted before a single argument
# shipped — the interpreter's own hint named the repair ("Did you mean?
# shell_quote", base log 2026-11-26). The repair is
# the recursion both arms meant — shell_quote itself, the same method the
# String, boolean, null and Hash-guard arms already ride. Integers render
# bare (an option gets a number, not a numeric string), Arrays render as
# @( ) of recursively-quoted elements, and a Hash inside an Array keeps the
# guard's own refusal rather than a NameError. What is NOT touched: the
# branch's double-quoted, $-interpolating value semantics are upstream
# behaviour and stay exactly as FOG-23 left them — every green pin below
# holds at base too, and the JSON arm (the one every in-repo caller rides)
# never enters this code.
class UnitPowershellNonjsonOptmapTest < Minitest::Test
  def build(**args)
    Fog::Hyperv::Utils::Powershell.build_call('Get-VM', args, _ps_version: 5).join(' ')
  end

  # --- the arms that never ran (red at base: NoMethodError shell_quoted) ----

  def test_an_array_value_ships_as_a_powershell_array_of_quoted_strings
    rendered = build(names: %w[web1 web2], _from_json: false)

    assert_includes rendered, %q{'Names'=@("web1", "web2")}
  end

  def test_an_integer_value_ships_bare_as_a_number
    # shell_quote with no always: leaves a digit string unquoted — the flag
    # receives 5, not "5" and not a crash.
    rendered = build(depth: 5, _from_json: false)

    assert_includes rendered, "'Depth'=5"
    refute_includes rendered, '"5"'
  end

  def test_a_nested_array_recurses_through_the_same_owner
    rendered = build(matrix: [%w[a], %w[b]], _from_json: false)

    assert_includes rendered, %q{'Matrix'=@(@("a"), @("b"))}
  end

  def test_a_hash_inside_an_array_keeps_the_guard_s_own_refusal
    # The Hash arm's informative refusal (not a NameError for the call this
    # file has never resolved since e6a1410) is what an array of hashes
    # deserves: it says WHAT
    # cannot render here and WHERE it must go instead.
    error = assert_raises(RuntimeError) do
      build(bad: [{ 'Class' => 'Ethernet' }], _from_json: false)
    end

    assert_includes error.message, 'Hashes need to be run through build_optmap'
  end

  # --- both-tree green pins: the arms that already worked -------------------

  def test_a_string_value_renders_exactly_as_fog23_pinned_it
    rendered = build(name: 'web1', _from_json: false)

    assert_match(/= @\{'Name'="web1"\}/, rendered)
  end

  def test_booleans_and_nil_still_render_as_powershell_literals
    rendered = build(on: true, off: false, missing: nil, _from_json: false)

    assert_includes rendered, '\'On\'=$true'
    assert_includes rendered, '\'Off\'=$false'
    assert_includes rendered, '\'Missing\'=$null'
  end

  def test_a_dollar_prefixed_value_still_passes_through_unquoted
    # The branch's documented expression-passthrough: $-leading strings ride
    # bare so callers can hand PowerShell a variable or expression.
    rendered = build(target: '$env:COMPUTERNAME', _from_json: false)

    assert_includes rendered, '\'Target\'=$env:COMPUTERNAME'
  end
end
