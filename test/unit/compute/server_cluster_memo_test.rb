# frozen_string_literal: true

require 'test_helper'

# FOG-28 (review F15): the lifetime of the Server model's cluster memos.
#
# Two answers about a machine are memoised on the model — #cluster_role and the
# tri-state #is_clustered — and this suite pins WHO may pay for them and WHEN
# they are re-asked. Before this PR the guard that decides whether the cluster
# question can be asked ran BEFORE the tri-state memo check, so every call to
# is_clustered on a model with an id dialled root/mscluster over WinRM even
# when the answer had been given seconds ago (Real#supports_clusters? was then
# a round trip per ask and nothing above the connection cached it; the model
# memo this PR added became the first cache, and FOG-36 later added the
# client-level one). And #reload refreshed
# the payload while leaving @cluster_role in place — so a model held across a
# live migration re-merged the machine's data and still answered the OLD
# owner_node, which is exactly the staleness #owner_node exists to avoid.
#
# The contract now: the first call asks the role once (the capability gate
# still ASKS twice on the cold path, but since FOG-36 a Real client answers
# the second ask from its own memo — and on the Mock these tests run on, an
# ask is a fixture read either way), every later call on a model that
# holds an answer is free, and #reload is the one thing that makes the model
# re-ask. A gate that flips AFTER an answer was given (the endpoint stops
# answering cluster questions) does not erase the answer — it was the
# endpoint's real answer while the endpoint could give it.
class UnitServerClusterMemoTest < Minitest::Test
  GUID = '2c60b75f-6437-4b39-b156-a90538413c1b'
  CLUSTERED_GUID = '20ff7fe3-fd54-425c-aa97-fbf3c2e7a868'

  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
  end

  def teardown
    Fog.unmock!
  end

  def plain_server
    Fog::Hyperv::Compute::Server.new(
      service: @client,
      id: GUID,
      name: 'mockvm9',
      computer_name: 'MOCK-HOST'
    )
  end

  # Counts endpoint probes for the rest of the test. Mock#supports_clusters?
  # answers from the get_cluster fixture instead of dialling — the stand-in
  # this fork gives the WQL probe a Real client pays over the wire. The count
  # is of ASKS: on a Real client of this build the first ask per session is
  # the one dial (FOG-36 memoises the answer), and on these Mocks every ask
  # re-reads the fixture, so a model-level memo pin measured here counts the
  # model's asks, exactly what this suite has always pinned.
  def probe_counter
    counter = { n: 0 }
    @client.define_singleton_method(:supports_clusters?) do
      counter[:n] += 1
      super()
    end
    counter
  end

  # -- new behaviour (red on the base gem) -------------------------------------

  # The page-cost fix: one model answering the cluster question many times
  # re-dials the endpoint only for its first answer. On the base gem every
  # call re-probed before its memo check, so this is exactly where the round
  # trips pile up.
  def test_an_answered_model_never_re_asks_the_endpoint
    # rubocop:disable Minitest/MultipleAssertions
    server = plain_server
    counter = probe_counter

    # The counter is live for the first ask; it is zeroed on the next line
    # so only the repeat reads below are measured.
    assert_same false, server.is_clustered
    counter[:n] = 0

    assert_same false, server.is_clustered
    assert_same false, server.is_clustered
    refute_predicate server, :clustered?
    assert_equal 0, counter[:n]
    # rubocop:enable Minitest/MultipleAssertions
  end

  # The staleness fix: #reload re-asks the cluster role. A model held across a
  # failover must answer the node the cluster names NOW, not the node the role
  # was read from before the move — re-merged payload or not.
  def test_reload_re_asks_the_cluster_role
    # rubocop:disable Minitest/MultipleAssertions
    vm = @client.servers.get('mockvm2')

    assert_equal 'mock-node2', vm.owner_node # the fixture's owner

    moved = {
      name: 'Virtual Machine mockvm2',
      owner_node: 'mock-node3',
      vm_id: CLUSTERED_GUID,
      virtual_machine_id: CLUSTERED_GUID
    }
    role_asks = { n: 0 }
    @client.define_singleton_method(:get_cluster_virtual_machine_role) do |_options = {}|
      role_asks[:n] += 1
      moved
    end

    assert vm.reload
    # The reload itself only re-reads the payload; the role re-ask happens
    # at the next cluster question the model is asked.
    assert_equal 'mock-node3', vm.owner_node
    assert_equal 1, role_asks[:n]
    # rubocop:enable Minitest/MultipleAssertions
  end

  # An answer the endpoint gave stays the model's answer until reload, even if
  # the endpoint would not answer a NEW question that way — the false tri-state
  # (and the nil) are for endpoints that were never able to answer, not for
  # gates that flipped after answering.
  def test_a_memoised_answer_survives_the_gate_flipping_afterwards
    vm = @client.servers.get('mockvm2')

    assert_same true, vm.is_clustered

    @client.define_singleton_method(:supports_clusters?) { false }

    assert_same true, vm.is_clustered
    assert_predicate vm, :clustered?
  end

  # A reload that finds NOTHING still re-asks: the memos are dropped before
  # the payload read, so a failed reload (the machine could not be read)
  # does not leave a stale cluster answer standing either.
  def test_a_reload_that_finds_nothing_still_re_asks
    # rubocop:disable Minitest/MultipleAssertions
    vm = @client.servers.get('mockvm2')

    assert_equal 'mock-node2', vm.owner_node # the fixture's owner

    moved = {
      name: 'Virtual Machine mockvm2',
      owner_node: 'mock-node3',
      vm_id: CLUSTERED_GUID,
      virtual_machine_id: CLUSTERED_GUID
    }
    role_asks = { n: 0 }
    @client.define_singleton_method(:get_vm) { |_options = {}| nil }
    @client.define_singleton_method(:get_cluster_virtual_machine_role) do |_options = {}|
      role_asks[:n] += 1
      moved
    end

    assert_nil vm.reload # the payload read found nothing...
    assert_equal 'mock-node3', vm.cluster_role.owner_node # ...but the answer was dropped anyway
    assert_predicate vm, :clustered? # rides the same fresh read, asks no more
    assert_equal 1, role_asks[:n]

    counter = probe_counter

    assert_same true, vm.is_clustered # its own memo is gone too: this goes to the endpoint
    assert_equal 1, counter[:n] # its own guard's probe; cluster_role's fresh answer asks none
    # rubocop:enable Minitest/MultipleAssertions
  end

  # -- pins: behaviour this PR must not lose (green on both trees) -------------

  # "Could not tell" is still not an answer: a refused role read propagates on
  # every call and is never memoised as true, false, or nil.
  def test_an_error_is_still_not_an_answer
    server = plain_server
    output = Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('', "Get-Cluster :\n+ FullyQualifiedErrorId : Boom\r\n", 1)
    @client.define_singleton_method(:get_cluster_virtual_machine_role) do |_options = {}|
      raise Fog::Hyperv::Errors::PSError.new(output, 'cluster read refused')
    end

    assert_raises(Fog::Hyperv::Errors::PSError) { server.is_clustered }
    assert_raises(Fog::Hyperv::Errors::PSError) { server.is_clustered }
  end

  # A machine with no id was never asked: nil, not false — and when it gets an
  # id it has been, because the nil of the tri-state is never memoised.
  def test_no_id_is_still_no_answer_and_a_later_id_is_still_asked
    server = Fog::Hyperv::Compute::Server.new(service: @client, name: 'mockvm9', computer_name: 'MOCK-HOST')

    assert_nil server.is_clustered

    counter = probe_counter
    server.id = GUID

    assert_same false, server.is_clustered
    assert_operator counter[:n], :>=, 1
  end
end
