# frozen_string_literal: true

require 'test_helper'

# The one WQL embedding site — Utils::Winrm#run_wql's WHERE builder — tested
# through the entry point that embeds, not against the primitive
# (wql_quote_test.rb covers that). The pre-FOG-34 render was String#inspect;
# these pins state the wire bytes the site must produce on the grammar
# MEASURED on HV-CL01 through this engine (2026-11-26): caller text rides a
# DOUBLE-quoted WQL literal with backslash and double-quote escaped (single-
# quoted literals are a measured engine refusal), numbers and booleans ride
# bare, keys are guarded by shape, and the site's pre-existing value filter
# (nil and false drop, present verbatim since upstream e6a1410) is pinned
# unchanged. The reject's third disjunct — keys starting with '_' — is
# pinned to its REAL reach, not its wording: camelize strips a leading
# underscore before the reject ever sees the key, so an underscore-prefixed
# keyword rides camelized. Measured at base.
class UnitWqlFilterSitesTest < Minitest::Test
  # Records the exact query string that would go down the wire. Same shape
  # as the composition harness: an offline client whose @connection answers
  # with a stub instance instead of dialling.
  class RecordingConnection
    attr_reader :queries

    def initialize
      @queries = []
    end

    def run_wql(query, namespace)
      @queries << [query, namespace]
      { xml_fragment: [{ 'Name' => 'stub-instance' }] }
    end
  end

  class OfflineClient < Fog::Hyperv::Compute::Real
    def connect(_endpoint = nil)
      nil
    end
  end

  def wql_client
    client = OfflineClient.new(
      hyperv_endpoint: 'http://wqlsite.invalid:5985/wsman',
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
    client.instance_variable_set(:@connection, RecordingConnection.new)
    client
  end

  def recorded_query(client, **where)
    client.send(:run_wql, 'SELECT * FROM Msvm_Fake', **where)
    client.instance_variable_get(:@connection).queries.first.first
  end

  # inspect rendered this "vm\"name" — a form this engine happens to accept
  # — but only by coincidence of Ruby's grammar; the site's own contract is
  # the measured escape, one backslash before the delimiter.
  def test_a_value_carrying_a_double_quote_is_escaped_and_closes_nothing
    query = recorded_query(wql_client, element_name: 'vm"name')

    assert_includes query, 'ElementName = "vm\\"name"'
  end

  # The measured collapse class: an escaped-backslash-safe render of
  # C:\VMs. Unescaped, \S is an invalid escape the provider refuses.
  def test_a_value_carrying_a_backslash_is_escaped_and_closes_nothing
    query = recorded_query(wql_client, element_name: 'C:\\VMs')

    assert_includes query, 'ElementName = "C:\\\\VMs"'
  end

  # The apostrophe is plain content inside a double-quoted literal —
  # doubling it would ask the engine for two.
  def test_a_value_carrying_a_single_quote_is_plain_content
    query = recorded_query(wql_client, element_name: "vm'name")

    assert_includes query, "ElementName = \"vm'name\""
  end

  def test_keys_still_ride_camelize
    query = recorded_query(wql_client, element_name: 'x')

    assert_includes query, 'ElementName ='
  end

  # A Symbol can carry any text, so the key position is guarded by shape,
  # and the guard fires before anything reaches the connection. (The kwargs
  # hash is built through to_sym so the key stays a Symbol while Ruby 3.0's
  # ** form stays valid for a key no bare-word literal can write.)
  def test_a_key_carrying_structure_is_refused_before_the_wire
    client = wql_client
    # A Symbol key with spaces has no spelling that satisfies the gem's own
    # HashSyntax/QuotedSymbols/SymbolConversion trio as a hash literal
    # (each fix invites the next cop — measured on the gem's .rubocop.yml);
    # a pairs array builds the same **where payload with zero offenses.
    pairs = [[:'a OR 1=1', 'x']]

    assert_raises(ArgumentError) { client.send(:run_wql, 'SELECT * FROM Msvm_Fake', **pairs.to_h) }
    assert_empty client.instance_variable_get(:@connection).queries
  end

  def test_numbers_ride_bare_and_text_still_quotes
    query = recorded_query(wql_client, enabled: true, creation_time: '20260101000000.000000+000')

    # enabled: true is filtered by the site's pre-existing FalseClass/nil
    # filter only for FALSE and nil — true still rides, bare:
    assert_includes query, 'Enabled = true'
    assert_includes query, 'CreationTime = "20260101000000.000000+000"'
  end

  # --- the site's pre-existing filters, pinned unchanged ---------------------

  def test_nil_and_false_values_are_still_dropped
    query = recorded_query(wql_client, element_name: 'keep', other: nil, enabled: false)

    assert_includes query, 'ElementName = "keep"'
    refute_includes query, 'Other'
    refute_includes query, 'Enabled'
  end

  # The reject asks camelized keys for a leading '_' that camelize has
  # already stripped — measured at base, where this exact query shipped as
  # `... AND NamespaceHint = "drop"`. The branch renders the same bytes
  # through the new owner, so this pin passes on both trees by measurement.
  def test_underscore_prefixed_keys_ride_camelize_as_the_base_ran
    query = recorded_query(wql_client, element_name: 'keep', _namespace_hint: 'drop')

    assert_includes query, 'ElementName = "keep"'
    assert_includes query, 'NamespaceHint = "drop"'
  end

  def test_no_where_still_ships_the_query_untouched
    client = wql_client
    client.send(:run_wql, 'SELECT * FROM Msvm_Fake')

    assert_equal ['SELECT * FROM Msvm_Fake', 'root/virtualization/v2/*'],
                 client.instance_variable_get(:@connection).queries.first
  end

  def test_a_value_without_a_literal_rendering_is_refused_before_the_wire
    # The old inspect arm stringified anything (a Time rode its unquoted,
    # zone-dependent default to_s — an invalid clause the provider
    # refused). Refusal is the new contract, and it happens before the
    # query goes anywhere.
    client = wql_client

    assert_raises(ArgumentError) { client.send(:run_wql, 'SELECT * FROM Msvm_Fake', element_name: Time.now) }
    assert_empty client.instance_variable_get(:@connection).queries
  end

  def test_a_control_character_value_is_refused_before_the_wire
    client = wql_client

    assert_raises(ArgumentError) { client.send(:run_wql, 'SELECT * FROM Msvm_Fake', element_name: "a\nb") }
    assert_empty client.instance_variable_get(:@connection).queries
  end
end
