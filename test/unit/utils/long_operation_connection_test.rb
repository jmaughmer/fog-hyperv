# frozen_string_literal: true

require 'test_helper'

# FOG-35 (whole-fork review, pull-timeout finding): the WinRM operation window is
# a per-CONNECTION number — the gem sends whatever operation_timeout the
# connection was built with in the OperationTimeout header of every message
# (winrm-2.3.9 wsmv/header.rb shared_headers, merged into all fourteen message
# builders), so the one way to give ONE call a different window is to build that
# call its own connection carrying the different number. This file pins the two
# halves: run_cmd/run_cmdlist route a caller-named window through
# long_operation_connection, and that builder answers a lazily-built connection
# (no dial — WinRM::Connection.new touches no socket) carrying the base
# connection's own options with ONLY the timeout widened, cached per
# endpoint-and-window, kept out of the host-routing @connections so it can never
# answer a host lookup, and refused at the call for a window that is not a
# positive Integer.
class UnitLongOperationConnectionTest < Minitest::Test
  # Stands in for a WinRM::Connection on the routing path: shell() counts its
  # opens and yields itself as the shell (run answers the empty clean run), so
  # an assertion about "which connection answered this call" is a count on a
  # fake that dials nothing.
  class FakeConnection
    attr_reader :connection_opts, :shell_opens, :run_scripts

    def initialize(opts)
      @connection_opts = opts
      @shell_opens = 0
      @run_scripts = []
    end

    def shell(_type)
      @shell_opens += 1
      yield self
    end

    def run(script)
      @run_scripts << script
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('', '', 0)
    end
  end

  # Routes through the REAL run_cmdlist and the real connection() bookkeeping,
  # but replaces connect (nothing dials) and, for the routing pins, the variant
  # builder itself — a routing test that answers its own variant still pins the
  # call site's arguments exactly. The long_operation_connection unit pins below
  # run against the real builder on this same client shape. ps_version is the
  # stub the ps_quote_sites_test offline client established: build_pscall asks
  # it for every call, and asking for real would run a probe command.
  class OfflineClient < Fog::Hyperv::Compute::Real
    attr_reader :dialed, :base_conn, :variant, :long_calls
    attr_accessor :stub_the_variant

    def initialize(options)
      @dialed = []
      @long_calls = []
      @stub_the_variant = false
      super
    end

    def ps_version
      { major: 5, minor: 1 }
    end

    private

    def connect(endpoint = nil)
      endpoint ||= @hyperv_endpoint
      @dialed << endpoint
      @base_conn = FakeConnection.new(
        endpoint: endpoint, user: 'u', password: 'p', transport: :negotiate,
        operation_timeout: @hyperv_operation_timeout
      )
      @connections[URI.parse(endpoint).host] = @base_conn
      @connection = @base_conn
      @connections['.'] = @base_conn
      @connections['localhost'] = @base_conn
      @base_conn
    end

    def long_operation_connection(base, timeout)
      @long_calls << [base, timeout]
      return @variant ||= FakeConnection.new(endpoint: 'http://variant.invalid:5985/wsman') if @stub_the_variant

      super
    end
  end

  ENDPOINT = 'http://recorded.invalid:5985/wsman'

  def setup
    @client = OfflineClient.new(hyperv_endpoint: ENDPOINT, hyperv_operation_timeout: 90)
  end

  # --- the routing: run_cmd's meta-argument reaches the builder, once -------------

  def test_a_named_window_routes_the_call_through_the_long_operation_connection
    @client.stub_the_variant = true
    @client.run_cmd('Get-Foo', _skip_json: true, _operation_timeout: 300)

    assert_equal [[@client.base_conn, 300]], @client.long_calls,
                 'the window travels with the call, built from the routed base connection'
    assert_equal 1, @client.variant.shell_opens, 'the window is an option on the ONE run, not an extra round trip'
    assert_equal 0, @client.base_conn.shell_opens, 'the widened call does not also run on the base connection'
  end

  # The both-trees pin: a call that names no window must ride the configured
  # connection exactly as it did before this feature existed — the builder is
  # not even reached. Green on base and branch by construction.
  def test_no_named_window_never_touches_the_builder
    @client.run_cmd('Get-Foo', _skip_json: true)

    assert_empty @client.long_calls, 'every ordinary call rides the configured connection, unchanged'
    assert_equal 1, @client.base_conn.shell_opens
  end

  def test_the_window_meta_does_not_leak_into_the_pscall_arguments
    @client.stub_the_variant = true
    @client.run_cmd('Get-Foo', _skip_json: true, _operation_timeout: 300)

    assert_includes @client.variant.run_scripts.first, 'Get-Foo'
    refute_includes @client.variant.run_scripts.first.to_s, '300',
                    'the number is a connection option; nothing about it belongs in the script text'
  end

  # --- the builder: a real lazy connection, one option wider, nothing else touched

  def test_the_variant_is_the_same_connection_options_with_only_the_window_widened
    base = @client.send(:connection, '.')

    variant = @client.send(:long_operation_connection, base, 300)

    refute_same base, variant, 'a per-call window needs its own connection — the header is per-connection'
    assert_instance_of WinRM::Connection, variant
    assert_equal 300, variant.instance_variable_get(:@connection_opts)[:operation_timeout]
  end

  def test_the_variant_carries_the_routed_connections_endpoint_and_credentials
    base = @client.send(:connection, '.')

    opts = @client.send(:long_operation_connection, base, 300).instance_variable_get(:@connection_opts)

    assert_equal base.connection_opts[:endpoint], opts[:endpoint]
    assert_equal base.connection_opts[:user], opts[:user]
    assert_equal base.connection_opts[:password], opts[:password]
  end

  def test_the_gem_pairs_the_widened_window_with_its_receive_timeout
    base = @client.send(:connection, '.')
    base_opts_before = base.connection_opts.dup

    opts = @client.send(:long_operation_connection, base, 300).instance_variable_get(:@connection_opts)

    # Measured gem fact (winrm-2.3.9 connection_opts.rb:38-41): a receive timeout
    # below the operation timeout is lifted to operation_timeout + 10 at build,
    # so the widened window carries its receive partner with it.
    assert_operator opts[:receive_timeout], :>=, 310
    assert_equal base_opts_before, base.connection_opts, 'the base connection is NOT mutated'
    assert_equal 90, base.connection_opts[:operation_timeout]
  end

  def test_the_variant_is_cached_per_endpoint_and_window
    base = @client.send(:connection, '.')

    same = @client.send(:long_operation_connection, base, 300)
    again = @client.send(:long_operation_connection, base, 300)
    wider = @client.send(:long_operation_connection, base, 600)

    assert_same same, again, 'one endpoint and window builds one connection; a per-call window is not a per-call cost'
    refute_same same, wider, 'a different window is a different connection'
    assert_equal 600, wider.instance_variable_get(:@connection_opts)[:operation_timeout]
  end

  def test_a_variant_never_answers_a_host_lookup
    base = @client.send(:connection, '.')
    registered_before = @client.instance_variable_get(:@connections).dup

    @client.send(:long_operation_connection, base, 300)

    assert_equal registered_before.keys.sort, @client.instance_variable_get(:@connections).keys.sort,
                 'a variant that answered a host lookup would silently move ordinary traffic onto a widened window'
    # The key set alone cannot see a variant OVERWRITING an existing key's
    # value (@connections['.'] = variant keeps the key set identical), so the
    # pin reads the value door the host lookup itself reads: the endpoint
    # sentinel entry must still be the very object it was before the variant
    # was built.
    assert_same base, @client.send(:connection, '.'),
                'a variant parked under the endpoint sentinel would answer host lookups on the widened window'
  end

  # connect() registers three doors, and a lookup on one provably never reads
  # another's entry — so the sentinel door alone would let a variant hide
  # under @connections['localhost'] or the configured-host key. Each door is
  # pinned through the lookup itself, to its own object. (Two tests because
  # the fork keeps every test method inside the 3-assertion
  # Minitest/MultipleAssertions bound its base tree honors everywhere.)
  def test_no_variant_can_hide_under_the_localhost_or_the_configured_host_entry
    base = @client.send(:connection, '.')

    @client.send(:long_operation_connection, base, 300)

    assert_same base, @client.send(:connection, 'localhost'),
                'a variant parked under the localhost entry would answer localhost lookups on the widened window'
    assert_same base, @client.send(:connection, 'recorded.invalid'),
                'a variant parked under the configured host would answer its lookups on the widened window'
  end

  def test_building_a_variant_dials_nothing
    base = @client.send(:connection, '.')
    dialed_before = @client.dialed.dup

    @client.send(:long_operation_connection, base, 300)

    assert_equal dialed_before, @client.dialed,
                 'WinRM::Connection.new is lazy — the variant dials on its first shell, like every other connection'
  end

  def test_a_window_that_is_not_a_positive_integer_zero_or_negative_is_refused_at_the_call
    base = @client.send(:connection, '.')

    assert_raises(ArgumentError) { @client.send(:long_operation_connection, base, 0) }
    assert_raises(ArgumentError) { @client.send(:long_operation_connection, base, -5) }
  end

  def test_a_window_that_is_not_a_positive_integer_string_or_nil_is_refused_at_the_call
    base = @client.send(:connection, '.')

    assert_raises(ArgumentError) { @client.send(:long_operation_connection, base, '300') }
    assert_raises(ArgumentError) { @client.send(:long_operation_connection, base, nil) }
  end
end
