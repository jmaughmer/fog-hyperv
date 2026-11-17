# frozen_string_literal: true

require 'test_helper'

class UnitConnectionTest < Minitest::Test
  # Fog::Hyperv::Compute::Real opens a WinRM connection on initialize, the
  # connection state checks under test do not need one
  class OfflineClient < Fog::Hyperv::Compute::Real
    def connect(_endpoint = nil)
      nil
    end
  end

  def setup
    @client = OfflineClient.new(
      hyperv_endpoint: 'http://hyperv.example:5985/wsman',
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
  end

  # run_wql resolves the xml_fragment list itself and hands back the first
  # instance of the query, so the checks read the projected field off it
  def test_valid_for_a_reachable_hyper_v_host
    @client.stub(:run_wql, { name: 'HYPERV-HOST' }) do
      assert_predicate @client, :valid?
    end
  end

  def test_invalid_when_the_query_returns_no_instance
    @client.stub(:run_wql, {}) do
      refute_predicate @client, :valid?
    end
  end

  def test_invalid_when_the_host_can_not_be_reached
    @client.stub(:run_wql, lambda { |*_args, **_opts| raise 'WSMAN: the server is not available' }) do
      refute_predicate @client, :valid?
    end
  end

  def test_supports_clusters_for_a_clustered_host
    @client.stub(:run_wql, { name: 'Cluster Group' }) do
      assert_predicate @client, :supports_clusters?
    end
  end

  def test_no_cluster_support_without_the_cluster_namespace
    @client.stub(:run_wql, lambda { |*_args, **_opts| raise 'WSMAN: invalid namespace' }) do
      refute_predicate @client, :supports_clusters?
    end
  end

  # run_wql appends the /* of the namespace itself, passing it in doubled it
  def test_cluster_query_targets_the_mscluster_namespace
    namespaces = []
    @client.define_singleton_method(:run_wql) do |_query, _namespace: nil, **_opts|
      namespaces << _namespace
      { name: 'Cluster Group' }
    end

    assert_predicate @client, :supports_clusters?
    assert_equal ['root/mscluster'], namespaces
  end

  # ---------------------------------------------------------------- other machines

  # A cluster's other nodes are reached over WinRM too, and they answer the way the
  # configured node does. Until this was derived, a second node was always asked on
  # plain HTTP/5985, so a cluster with WinRM on 5986 over HTTPS could not be
  # managed: the request went to a port nothing listens on.
  def test_a_second_node_keeps_the_configured_scheme_port_and_path
    endpoints = []
    client = offline_client('https://hyperv.example:5986/wsman', endpoints)

    client.send(:connection, 'node2')

    assert_equal ['https://node2.example:5986/wsman'], endpoints
  end

  # The other half of the same rule: the endpoint that was configured is used as it
  # was given, not rebuilt through the same code path
  def test_the_configured_endpoint_is_used_as_it_was_given
    endpoints = []
    client = offline_client('https://hyperv.example:5986/wsman', endpoints)

    client.send(:connection, '.')

    assert_equal ['https://hyperv.example:5986/wsman'], endpoints
  end

  # A port left out of the configured endpoint is the scheme's default, and that is
  # the port a second node answers on too — pinning URI's behaviour here because
  # writing 443 explicitly is what makes an https listener work
  def test_an_endpoint_without_a_port_keeps_its_scheme_and_path
    endpoints = []
    client = offline_client('https://hyperv.example/wsman', endpoints)

    client.send(:connection, 'node2')

    assert_equal ['https://node2.example:443/wsman'], endpoints
  end

  # No endpoint at all (a client built from neither endpoint nor host) keeps the
  # answer it always gave rather than raising on a nil URI
  def test_a_client_without_an_endpoint_falls_back_to_the_plain_listener
    endpoints = []
    client = offline_client(nil, endpoints)

    client.send(:connection, 'node2')

    assert_equal ['http://node2.example:5985/wsman'], endpoints
  end

  # ---------------------------------------------------------------- auth and TLS options
  #
  # ruby-winrm's :negotiate transport always wraps NTLM tokens and never attempts
  # a Kerberos leg, and the connection used to be built with TLS peer
  # verification off no matter what the endpoint was. NTLM is deprecated by its
  # vendor with disabling it by default as the stated end state, and an
  # unverified https listener authenticates nobody, so both are now things a
  # caller can say otherwise about. These pin what a connection is built from.

  def test_an_http_endpoint_carries_no_tls_options
    opts = opts_for 'http://hyperv.example:5985/wsman',
                    hyperv_ssl_verify: false,
                    hyperv_ca_trust_path: '/etc/pki/hyperv-ca.pem'

    refute opts.key?(:no_ssl_peer_verification), 'nothing to verify a peer of over plain http'
    refute opts.key?(:ca_trust_path)
  end

  def test_an_https_endpoint_verifies_the_peer_by_default
    opts = opts_for 'https://hyperv.example:5986/wsman'

    refute opts.key?(:no_ssl_peer_verification), 'verification stays on unless asked off'
  end

  # The opt-out still has to reach the gem, or a self-signed listener inside a
  # closed network is unreachable with no way to say so
  def test_verification_can_be_switched_off
    opts = opts_for 'https://hyperv.example:5986/wsman', hyperv_ssl_verify: false

    assert_equal true, opts[:no_ssl_peer_verification]
  end

  # A form or a YAML file hands booleans over as strings; 'false' has to mean
  # false and not the truthiness of a non-nil object
  def test_a_string_says_no_the_same_as_the_boolean
    %w[false f no 0 FALSE].each do |given|
      opts = opts_for 'https://hyperv.example:5986/wsman', hyperv_ssl_verify: given
      assert_equal true, opts[:no_ssl_peer_verification], "#{given.inspect} did not switch verification off"
    end

    opts = opts_for 'https://hyperv.example:5986/wsman', hyperv_ssl_verify: 'true'
    refute opts.key?(:no_ssl_peer_verification)
  end

  def test_the_tls_trust_and_client_certificate_paths_pass_through
    opts = opts_for 'https://hyperv.example:5986/wsman',
                    hyperv_ca_trust_path: '/etc/pki/hyperv-ca.pem',
                    hyperv_client_cert: '/etc/pki/foreman.crt',
                    hyperv_client_key: '/etc/pki/foreman.key',
                    hyperv_key_pass: 'st3ng'

    assert_equal '/etc/pki/hyperv-ca.pem', opts[:ca_trust_path]
    assert_equal '/etc/pki/foreman.crt', opts[:client_cert]
    assert_equal '/etc/pki/foreman.key', opts[:client_key]
    assert_equal 'st3ng', opts[:key_pass]
  end

  # The transports that do not speak NTLM become the default when named, which
  # is what lets a deployment stop depending on a deprecated protocol without
  # having to know the transport names to do it
  def test_the_transport_defaults_follow_what_was_named
    assert_equal :negotiate, opts_for('http://hyperv.example:5985/wsman')[:transport]
    assert_equal :kerberos,
                 opts_for('http://hyperv.example:5985/wsman', hyperv_realm: 'EXAMPLE.COM')[:transport]
    assert_equal :ssl,
                 opts_for('https://hyperv.example:5986/wsman', hyperv_client_cert: '/etc/pki/foreman.crt')[:transport]
    # a realm is asked before a certificate: both named means Kerberos authenticates
    assert_equal :kerberos,
                 opts_for('https://hyperv.example:5986/wsman',
                          hyperv_realm: 'EXAMPLE.COM', hyperv_client_cert: '/etc/pki/foreman.crt')[:transport]
  end

  def test_an_explicit_transport_beats_the_defaults
    opts = opts_for 'https://hyperv.example:5986/wsman',
                    hyperv_transport: 'Negotiate',
                    hyperv_realm: 'EXAMPLE.COM',
                    hyperv_client_cert: '/etc/pki/foreman.crt'

    assert_equal :negotiate, opts[:transport]
  end

  def test_the_credentials_and_the_realm_reach_the_connection
    opts = opts_for 'https://hyperv.example:5986/wsman', hyperv_realm: 'EXAMPLE.COM'

    assert_equal 'test', opts[:user]
    assert_equal 'test', opts[:password]
    assert_equal 'EXAMPLE.COM', opts[:realm]
    assert_equal 'https://hyperv.example:5986/wsman', opts[:endpoint]
  end

  private

  def opts_for(endpoint, options = {})
    client = OfflineClient.new(
      {
        hyperv_endpoint: endpoint,
        hyperv_username: 'test',
        hyperv_password: 'test'
      }.merge(options)
    )
    client.send(:winrm_connection_opts, endpoint)
  end

  # A client that records the endpoints it would connect to instead of connecting,
  # and resolves a short node name without asking a host to do it
  def offline_client(endpoint, endpoints)
    client = OfflineClient.new(
      hyperv_endpoint: endpoint,
      hyperv_username: 'test',
      hyperv_password: 'test'
    )
    # the client's own initialize calls connect, before this recorder exists
    client.define_singleton_method(:connect) do |ep = nil|
      endpoints << ep
      nil
    end
    client.define_singleton_method(:run_cmd) do |*_args, **_opts|
      { host_name: 'node2.example' }
    end
    client
  end
end
