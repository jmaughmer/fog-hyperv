# frozen_string_literal: true

require 'test_helper'

# FOG-36 (whole-fork review, supports_clusters? finding): Real#supports_clusters?
# is a live root/mscluster WQL round trip. The FOG-28 model memos keep it off
# steady-state model calls, but every cold model's FIRST cluster question still
# paid it — and the cold path paid it twice, because cluster_queriable? probes
# and then cluster_role's own askable-guard probes again before the role read.
# The plugin's stand-alone destroy gate asks on every destroy attempt on an
# endpoint that can never answer yes. A host's cluster membership does not
# change underneath a live client session any more than its reported identity
# does (the connection's own host-name set is already trusted for the whole
# connection lifetime — PLG-43), so this client answers the question once and
# remembers, true and false alike. What remembering means on purpose: a host
# that joins or leaves a cluster while a client is alive keeps the answer it
# gave — rebuilding the compute resource's connection (the operator action
# that already refreshes everything else about the endpoint) starts a client
# that re-asks. Mock deliberately does NOT memoize: its answer is a fixture
# read, not a dial, and the mock-based suites (FOG-28's among them) redefine
# the method to model gate flips, which a memo would only make stale for free.
class UnitSupportsClustersClientMemoTest < Minitest::Test
  GUID = '2c60b75f-6437-4b39-b156-a90538413c1b'

  # The OfflineClient shape this fork established (connect dials nothing), with
  # run_wql replaced by the probe counter: the method under test is the real
  # Real#supports_clusters?, and what a test asserts about is how many times it
  # sent its query over the wire.
  class ProbeCountingClient < Fog::Hyperv::Compute::Real
    attr_reader :wql_calls
    attr_accessor :wql_answer

    def initialize(options)
      @wql_calls = []
      @wql_answer = :rows
      super
    end

    private

    def connect(_endpoint = nil)
      @connection = Struct.new(:logger).new(Struct.new(:level).new(nil))
    end

    def run_wql(query, _namespace: 'root/virtualization/v2', **_where)
      @wql_calls << [query, _namespace]
      case @wql_answer
      when :rows then { name: 'Cluster Group' }
      else
        output = Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('', 'WSMAN: invalid namespace', 1)
        raise Fog::Hyperv::Errors::PSError.new(output, 'mscluster read refused')
      end
    end
  end

  def setup
    @client = ProbeCountingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  def mscluster_probes(client = @client)
    client.wql_calls.count { |(_query, namespace)| namespace == 'root/mscluster' }
  end

  # --- new behaviour (red on base) -------------------------------------------------

  # The cold-model win: the first cluster question of a client session dials,
  # the second does not. Base re-ran the query on every call — this is the
  # round trip every fresh model's classification paid.
  def test_a_second_cluster_question_on_the_same_client_dials_once
    assert_same true, @client.supports_clusters?

    assert_same true, @client.supports_clusters?
    assert_equal 1, mscluster_probes, 'the remembered answer is not a second round trip'
  end

  # The destroy-gate win, and the half of the memo a true-only cache would
  # miss: the stand-alone endpoint that answers no (its root/mscluster does
  # not even exist — the read refuses) is remembered as no too. The plugin's
  # stand-alone destroy path asks on EVERY attempt; each refused probe is a
  # command round trip (~3-5 s of wire time at this fork's established
  # satellite budget, the whole-fork review's RTT budget) the memo erases
  # after the first.
  def test_a_standalone_host_is_not_asked_twice_either
    @client.wql_answer = :refused

    assert_same false, @client.supports_clusters?
    assert_same false, @client.supports_clusters?
    assert_equal 1, mscluster_probes, 'the no answer rides the same memo — the destroy-gate probe count'
  end

  # The double-probe the review measured: a COLD model's first is_clustered
  # asks cluster_queriable? (probe) and then cluster_role's askable-guard
  # (probe again) before any role read. With the client memo the second ask
  # hits the remembered answer, so the cold path pays ONE mscluster dial —
  # the role read itself (Server#cluster_role dials
  # service.cluster_virtual_machine_roles.get(vm_id:)) is a different request
  # and is untouched, counted through the collection stand-in below.
  def test_the_cold_cluster_question_asks_the_host_once_not_twice
    role_asks = { n: 0 }
    roles = Object.new
    roles.define_singleton_method(:get) do |_options = {}|
      role_asks[:n] += 1
      nil
    end
    @client.define_singleton_method(:cluster_virtual_machine_roles) { roles }
    server = Fog::Hyperv::Compute::Server.new(service: @client, id: GUID, name: 'vm1', computer_name: 'HV-NODE1')

    assert_same false, server.is_clustered
    assert_equal 1, mscluster_probes, 'base dialled twice here: guard + askable-guard'
    assert_equal 1, role_asks[:n]
  end

  # The accepted staleness, pinned so it is a decision and not an accident:
  # an endpoint that joins a cluster mid-session keeps the earlier no for this
  # client's life. Nothing in this gem watches for the join; a fresh client
  # (compute-resource reconnect) is the re-ask, the same way the connection's
  # identity facts behave.
  def test_the_memo_holds_across_a_cluster_that_forms_underneath_the_client
    @client.wql_answer = :refused

    assert_same false, @client.supports_clusters?

    @client.wql_answer = :rows

    assert_same false, @client.supports_clusters?, 'the remembered answer outlives the flip — by design'
    assert_equal 1, mscluster_probes
  end

  # --- pins: behaviour that must not change (green on both trees) ------------------

  # The one call that IS made still asks exactly the measured query in the
  # measured namespace — the memo must not change what is asked, only how
  # often. Byte-exact on base and branch.
  def test_the_first_cluster_question_asks_the_exact_query_in_the_exact_namespace
    assert_same true, @client.supports_clusters?

    assert_equal [['SELECT Name FROM MSCluster_ResourceGroup', 'root/mscluster']], @client.wql_calls
  end

  # The refusal still reads as no on the FIRST call (fail-closed), still
  # exactly one probe: the memo adds memory, not caution.
  def test_a_refused_first_answer_is_still_false_and_still_asks_once
    @client.wql_answer = :refused

    assert_same false, @client.supports_clusters?
    assert_equal 1, mscluster_probes
  end

  # Mock is not memoized: it answers from its fixtures fresh every ask. Its
  # answer costs no wire, and the mock-based suites redefine the method to
  # model gate flips mid-test — a memo there buys nothing and could stale a
  # redefinition. Green on base (no memo) and on branch (memo is Real-only).
  def test_the_mock_client_answers_from_its_fixtures_every_time_it_is_asked
    Fog.mock!
    mock_client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
    asks = { n: 0 }
    mock_client.define_singleton_method(:supports_clusters?) do
      asks[:n] += 1
      super()
    end

    assert_same true, mock_client.supports_clusters?
    assert_same true, mock_client.supports_clusters?
    assert_equal 2, asks[:n], 'Mock re-reads its fixture per ask — the memo lives on Real only'
  ensure
    Fog.unmock!
  end
end
