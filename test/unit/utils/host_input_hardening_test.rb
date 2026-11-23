# frozen_string_literal: true

require 'test_helper'

# FOG-9: the host strings this gem accepts are checked before they can compose
# an endpoint or reach the wire, and fog never completes a caller's name with a
# remote GetHostByName — that call was the one place a host string became
# remote PowerShell text. The builder validator and the connection-path gate
# are one shared rule (Fog::Hyperv::Utils::HostInput), so a probe of the pure
# function is a probe of both.
class UnitHostInputHardeningTest < Minitest::Test
  # Fog::Hyperv::Compute::Real connects on initialize; connect is stubbed, so
  # every test below sees what the builder DID with the option, not a machine.
  class BuilderClient < Fog::Hyperv::Compute::Real
    class FakeConnection
      attr_reader :endpoint, :logger

      def initialize(endpoint)
        @endpoint = endpoint
        @connection_opts = { endpoint: endpoint }
        @logger = Struct.new(:level).new(nil)
      end
    end

    attr_reader :dialed, :cmd_calls

    def initialize(options)
      @dialed = []
      @cmd_calls = []
      super
    end

    private

    def connect(endpoint = nil)
      endpoint ||= @hyperv_endpoint
      return nil if endpoint.nil?

      @dialed << endpoint
      conn = FakeConnection.new(endpoint)
      @connections[URI.parse(endpoint).host] = conn
      @connection = conn
      @connections['.'] = conn
      @connections['localhost'] = conn
      conn
    end

    # The completion this PR removes was a run_cmd; a fake that raises on any
    # command proves that no completion (or anything else) went down the shell.
    def run_cmd(cmd, _skip_json: false, **_opts)
      @cmd_calls << cmd
      raise "no shell call is stubbed, and none should happen: #{cmd}"
    end
  end

  # Same client, with a cache-clearing knob: drop_cache! forces the
  # composition branch inside connection() — the branch the completion used to
  # occupy — which in production the set check plus the cache scan leave
  # unreachable for names the set answers for.
  class CompositionClient < BuilderClient
    def drop_cache!
      @connections.clear
    end
  end

  FQDN_HTTP = 'http://hyperv.lab.example:5985/wsman'
  FQDN_HTTPS = 'https://hyperv.lab.example:5986/wsman'

  def build(**options)
    BuilderClient.new({ hyperv_username: 'u', hyperv_password: 'p' }.merge(options))
  end

  def composition_client(endpoint = FQDN_HTTP)
    CompositionClient.new(hyperv_endpoint: endpoint, hyperv_username: 'u', hyperv_password: 'p')
  end

  # --- the builder validator: hyperv_host composes an endpoint verbatim, so
  # it is checked BEFORE it composes one. These payloads are red at base,
  # where each one built an endpoint and dialed it.

  def test_a_hyperv_host_with_command_substitution_is_refused_before_any_dial
    err = assert_raises(Fog::Hyperv::Errors::InvalidHostInput) do
      build(hyperv_host: '$(whoami)')
    end
    assert_includes err.message, 'hyperv_host'
    assert_includes err.message, '$(whoami)'
  end

  def test_a_hyperv_host_with_backticks_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_host: 'hyperv`whoami`') }
  end

  def test_a_hyperv_host_carrying_a_statement_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_host: 'hyperv; Remove-Item *') }
  end

  def test_a_hyperv_host_that_is_not_a_string_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_host: 42) }
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_host: :hyperv) }
  end

  def test_a_hyperv_host_of_dns_impossible_length_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_host: 'a' * 254) }
  end

  # --- the builder validator on hyperv_endpoint: the host INSIDE the URI
  # gets the same rule, before URI-shaped errors become someone else's crash.

  def test_an_endpoint_host_with_command_substitution_is_refused
    # URI.parse itself accepts "$(x)" in a host — the shape rule is what refuses it.
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_endpoint: 'http://hyperv$(x):5985/wsman') }
  end

  def test_an_endpoint_the_uri_parser_refuses_is_refused_as_a_host_input
    # A backtick is outside URI's host grammar; the refusal is still the
    # gem's own typed error, not a URI::InvalidURIError leaking out of
    # initialize.
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_endpoint: 'http://hyperv`x:5985/wsman') }
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_endpoint: 'http://a b:5985/wsman') }
  end

  def test_an_endpoint_without_a_host_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_endpoint: 'http://:5985/wsman') }
  end

  def test_an_endpoint_on_a_scheme_that_is_not_winrm_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_endpoint: 'ftp://hyperv.lab.example:21') }
  end

  def test_an_unqualified_host_on_an_https_endpoint_is_refused
    # A certificate subject and a Kerberos service principal are host-
    # qualified; upstream's silent answer to exactly this name was a plain
    # http endpoint. Refuse, do not guess.
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_endpoint: 'https://hv-node2:5986/wsman') }
  end

  # --- what must keep working: every real configuration composes and dials
  # exactly as before.

  def test_ordinary_hosts_compose_and_dial_exactly_as_before
    assert_equal ['http://hyperv:5985/wsman'], build(hyperv_host: 'hyperv').dialed
    assert_equal ['http://HV-NODE2:5985/wsman'], build(hyperv_host: 'HV-NODE2').dialed
    assert_equal ['http://192.168.1.71:5985/wsman'], build(hyperv_host: '192.168.1.71').dialed
  end

  def test_ordinary_endpoints_are_left_exactly_as_they_were_given
    assert_equal ['http://hyperv.lab.example:5985/wsman'], build(hyperv_endpoint: FQDN_HTTP).dialed
    assert_equal ['http://[fd00::1]:5985/wsman'], build(hyperv_endpoint: 'http://[fd00::1]:5985/wsman').dialed
    assert_equal ['https://hyperv.lab.example:5986/wsman'], build(hyperv_endpoint: FQDN_HTTPS).dialed
  end

  def test_a_host_less_build_is_left_alone
    assert_equal [], build.dialed
  end

  # --- the completion path inside connection(): no remote name completion is
  # ever attempted, the name composes verbatim, and TLS refuses the
  # unqualified one.

  def test_a_short_name_composes_its_endpoint_verbatim_without_asking_a_machine
    client = composition_client
    client.drop_cache!

    client.send(:connection, 'hyperv')

    assert_equal [FQDN_HTTP, 'http://hyperv:5985/wsman'], client.dialed
    assert_empty client.cmd_calls
  end

  def test_a_dotted_name_in_the_set_composes_without_asking_a_machine_either
    client = composition_client
    client.drop_cache!

    client.send(:connection, 'hyperv.lab.example')

    assert_equal [FQDN_HTTP, FQDN_HTTP], client.dialed
    assert_empty client.cmd_calls
  end

  def test_an_unqualified_name_is_refused_on_an_https_endpoint
    client = composition_client(FQDN_HTTPS)
    client.drop_cache!

    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { client.send(:connection, 'hyperv') }
    assert_equal [FQDN_HTTPS], client.dialed
    assert_empty client.cmd_calls
  end

  def test_a_dotted_name_on_an_https_endpoint_still_composes
    client = composition_client(FQDN_HTTPS)
    client.drop_cache!

    client.send(:connection, 'hyperv.lab.example')

    assert_equal [FQDN_HTTPS, FQDN_HTTPS], client.dialed
  end

  def test_a_name_carrying_payload_is_refused_before_anything_else_runs
    client = composition_client

    assert_raises(Fog::Hyperv::Errors::PSError) { client.send(:connection, 'hyperv.lab.example;ipconfig') }
    assert_raises(Fog::Hyperv::Errors::PSError) { client.send(:connection, '$(whoami)') }
  end

  # --- the probe (B8): one pure function behind both validators, so PLG-22's
  # runtime gate can trust the constants without a machine.

  def test_the_probe_accepts_every_shape_a_real_host_has
    %w[hyperv HV-NODE2 hyperv.lab.example 192.168.1.71 [fd00::1] a].each do |host|
      assert Fog::Hyperv::Utils::HostInput.valid_host_input?(host), "#{host} is a host"
    end
  end

  def test_the_probe_refuses_every_shape_that_could_reach_a_shell
    ['$(whoami)', 'hyperv`x`', 'hyperv;ipconfig', 'hyperv ip', "hyperv'x", 'hyperv"x',
     'hyperv|ip', 'hyperv&x', '<hyperv>', '-hyperv', 'hyperv-', '', ' ', 'a' * 254,
     nil, 42, :hyperv].each do |host|
      refute Fog::Hyperv::Utils::HostInput.valid_host_input?(host), "#{host.inspect} is not a host"
    end
  end

  def test_the_probe_and_the_connection_gate_answer_as_one_rule
    client = composition_client

    ['hyperv', 'hyperv.lab.example', '192.168.1.71', '$(whoami)', 'hyperv`x`', 'a b', '', 'a' * 254].each do |host|
      assert_equal Fog::Hyperv::Utils::HostInput.valid_host_input?(host),
                   client.send(:shell_safe_host?, host),
                   "#{host.inspect} answers differently in the two gates"
    end
  end

  def test_the_builder_validator_shares_the_probe_rule
    # The refusal for the same value comes from the same rule at both doors:
    # what the probe refuses, the builder refuses.
    ['$(whoami)', 'hyperv`x`', 'hyperv;ip', 'a b', 42, :hyperv, 'a' * 254].each do |host|
      refute Fog::Hyperv::Utils::HostInput.valid_host_input?(host)
      assert_raises(Fog::Hyperv::Errors::InvalidHostInput) { build(hyperv_host: host) }
    end
  end

  # --- the capability the plugin's enablement gate reads.

  def test_the_build_declares_the_input_hardening_capability
    # PLG-22's runtime gate reads the five entries together and PLG-14's
    # capacity read rides the sixth, so the whole list is pinned exactly —
    # another behaviour has to be added here on purpose, not by accident.
    # PLG-30's failback write is that seventh, added on purpose.
    assert_equal %i[tri_state_cluster exact_host_connection literal_path_destructive stdout_json_hygiene
                    input_hardening cluster_capacity_projection cluster_role_failback],
                 Fog::Hyperv::CAPABILITIES
  end

  def test_the_mock_provider_answers_the_capability
    Fog.mock!
    client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')

    assert_includes Fog::Hyperv::CAPABILITIES, :input_hardening
    assert_predicate client, :supports_input_hardening?
  ensure
    Fog.unmock!
  end
end
