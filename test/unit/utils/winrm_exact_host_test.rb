# frozen_string_literal: true

require 'test_helper'

# FOG-11: connection(host) answers only for hosts inside the instance's
# configured endpoint set — the endpoint itself, the aliases connect()
# registered for it, and short names addressing a node under a registered host.
# A name carried by request data (a filter, or a model's computer_name) can no
# longer point the client, and its NTLM credentials, at a host nobody
# configured. connection() is a private method of the Winrm utils; the tests
# reach it the way run_cmdlist does, from inside the object.
class UnitWinrmExactHostTest < Minitest::Test
  # Fog::Hyperv::Compute::Real opens a WinRM connection on initialize; connect
  # is replaced with a faithful registration of what the real connect()
  # registers — the endpoint host, the discovered aliases when the machine
  # answers, and the sentinels — with no machine behind any of it.
  class OfflineClient < Fog::Hyperv::Compute::Real
    # Stands in for a WinRM::Connection: what the registration path reads from
    # a connection is the endpoint inside @connection_opts, and connect() sets
    # the logger level on it.
    class FakeConnection
      attr_reader :endpoint, :logger

      def initialize(endpoint)
        @endpoint = endpoint
        @connection_opts = { endpoint: endpoint }
        @logger = Struct.new(:level).new(nil)
      end
    end

    attr_reader :dialed, :cmd_calls, :connections
    attr_accessor :discovered_fqdn, :discovered_shortname, :discovery_fails

    def initialize(options)
      @dialed = []
      @cmd_calls = []
      @discovery_fails = false
      super
    end

    private

    def connect(endpoint = nil)
      endpoint ||= @hyperv_endpoint
      @dialed << endpoint
      conn = FakeConnection.new(endpoint)
      fqdn = URI.parse(endpoint).host
      @connections[fqdn] = conn

      hostname, resolved = discover_host_names(fqdn)
      @connections[hostname] ||= conn if hostname
      @connections[resolved] ||= conn if resolved

      if endpoint == @hyperv_endpoint
        @connection = conn
        @connections['.'] = conn
        @connections['localhost'] = conn
      end
      conn
    end

    # The one remote command of the routing path, answered from the knobs the
    # test sets: discovery (the $env:computerName probe, answered with
    # streams). Completion is GONE — FOG-9 removed the remote GetHostByName —
    # so a completion call now falls into the raise below, and the suite fails
    # the moment anything starts completing names again.
    def run_cmd(cmd, _skip_json: false, **opts)
      @cmd_calls << [cmd, opts]
      discovery = cmd.include?('$env:computerName')
      raise 'discovery is stubbed to fail' if @discovery_fails && discovery

      raise "only discovery is stubbed, and this call proves completion came back: #{cmd}" unless discovery

      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(
        "#{[@discovered_shortname, @discovered_fqdn].compact.join('; ')}\n", '', 0
      )
    end
  end

  FQDN_ENDPOINT = 'http://hyperv.lab.example:5985/wsman'
  IP_ENDPOINT = 'http://192.168.1.71:5985/wsman'

  def fqdn_client
    build_client(FQDN_ENDPOINT)
  end

  def ip_client
    build_client(IP_ENDPOINT)
  end

  def build_client(endpoint)
    OfflineClient.new(hyperv_endpoint: endpoint, hyperv_username: 'u', hyperv_password: 'p')
  end

  def with_discovery(client)
    client.discovered_fqdn = 'hv-node10.lab.example'
    client.discovered_shortname = 'HV-NODE10'
    # Re-run the registration connect() did, now that the machine can answer
    client.send(:connect, client.instance_variable_get(:@hyperv_endpoint))
    client
  end

  def connect_to(client, host)
    client.send(:connection, host)
  end

  def completion_attempts(client)
    client.cmd_calls.select { |cmd, _opts| cmd.include?('GetHostByName("') }
  end

  # Red test (a): a dotted, foreign host is refused. Under the prefix match a
  # request filter naming another machine reached endpoint_for and dialed it,
  # carrying the configured credentials there.
  def test_a_foreign_dotted_host_is_refused
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'cluster-node.evil.example') }
  end

  def test_refusing_a_foreign_host_dials_nothing_new
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'evil.example.com') }
    assert_equal [FQDN_ENDPOINT], client.dialed
  end

  def test_a_dotted_host_sharing_the_endpoint_prefix_is_refused
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'hyperv.evil.example') }
  end

  def test_the_link_local_metadata_address_is_refused
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, '169.254.169.254') }
  end

  # The lazy-load vector: a value carrying shell metacharacters is refused as
  # an unknown name, and nothing of it reaches a shell or a URI.
  def test_a_host_with_shell_metacharacters_is_refused
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, "hyperv.lab.example'; Remove-Item \\*") }
  end

  def test_a_non_string_host_is_refused
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, :host) }
  end

  # Red test (b): with discovery failed, a short name is not in the set, and
  # the refusal happens with NO completion attempt — GetHostByName is never
  # asked to resolve a name the set never accepted.
  def test_discovery_failure_refuses_short_names
    client = fqdn_client
    client.discovery_fails = true

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'hv-node10') }
  end

  def test_discovery_failure_leaves_no_completion_attempted
    client = fqdn_client
    client.discovery_fails = true

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'hv-node10') }
    assert_empty completion_attempts(client)
  end

  # The self rung the plan requires to survive: an IP-configured resource
  # (the lab's shape) still answers for the names its machine registered at
  # connect time, routing to its own connection.
  def test_an_ip_endpoint_answers_for_a_discovered_name
    client = with_discovery(ip_client)

    assert_same client.connections['192.168.1.71'], connect_to(client, 'HV-NODE10')
  end

  def test_a_discovered_fqdn_is_in_the_set_itself
    client = with_discovery(ip_client)

    assert_same client.connections['192.168.1.71'], connect_to(client, 'hv-node10.lab.example')
  end

  # The prefix rung stays for short names only: hyperv addresses the node the
  # endpoint itself is, exactly as before — but hyperv.evil.example above did
  # not, because a dotted value must match a registered name exactly.
  def test_a_short_prefix_of_the_endpoint_host_still_routes
    client = fqdn_client

    assert_same client.connections['hyperv.lab.example'], connect_to(client, 'hyperv')
  end

  # The rung is FIRST-LABEL equality, not plain prefix matching: under the old
  # start_with? scan the name local routed to the localhost sentinel and hyp
  # to the endpoint, neither of which is a node address.
  def test_a_partial_first_label_is_refused
    client = fqdn_client

    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'local') }
    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'hyp') }
    assert_raises(Fog::Hyperv::Errors::PSError) { connect_to(client, 'hyperv-la') }
  end

  # The pair-store fix: the cache stores the connection, never the [key,
  # connection] pair the find call returns. A pair under a short key crashed
  # the next scan that read it — undefined method for Array.
  def test_the_pair_store_keeps_connections_not_pairs
    client = fqdn_client
    connect_to(client, 'hyperv')

    assert client.connections.values.none?(Array)
  end

  def test_a_short_name_resolved_twice_returns_the_same_connection
    client = fqdn_client
    first = connect_to(client, 'hyperv')

    assert_same first, connect_to(client, 'hyperv')
  end

  def test_the_configured_endpoint_answers_for_itself
    client = fqdn_client

    assert_same client.connections['hyperv.lab.example'], connect_to(client, 'hyperv.lab.example')
  end

  def test_the_configured_endpoint_answers_case_insensitively
    client = fqdn_client

    assert_same client.connections['hyperv.lab.example'], connect_to(client, 'HYPERV.Lab.Example')
  end

  def test_an_ip_endpoint_answers_for_its_literal_address
    client = ip_client

    assert_same client.connections['192.168.1.71'], connect_to(client, '192.168.1.71')
  end

  # The '.' sentinel and localhost stay registered by connect(), so the
  # documented default call shape (run_cmd with no target) routes as before.
  def test_the_sentinel_names_route_to_the_configured_endpoint
    client = fqdn_client

    assert_same client.connections['hyperv.lab.example'], connect_to(client, '.')
    assert_same client.connections['hyperv.lab.example'], connect_to(client, 'localhost')
  end

  # The capability the plugin pins, and both provider answers on it.
  def test_the_build_declares_the_capability
    assert_includes Fog::Hyperv::CAPABILITIES, :exact_host_connection
  end

  def test_the_real_provider_answers_true_without_being_asked_anything
    assert_predicate fqdn_client, :supports_exact_host_connections?
  end

  def test_the_mock_provider_declares_the_same_capability
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    assert_predicate client, :supports_exact_host_connections?
  ensure
    Fog.unmock!
  end
end
