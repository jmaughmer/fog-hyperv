# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/requests/set_cluster_virtual_machine_role_owner_nodes'

# PLG-36: preferred owners are WRITABLE on this build. Evidence section 76
# measured the whole contract on HV-CL01 before a line of this ran: the cmdlet
# is Set-ClusterOwnerNode with -Owners (the -Nodes call that made section 60
# record a "silent no-op" died on parameter binding, not on the cluster); the
# write sticks across shells; -Owners '' restores the unset [] (while
# -Owners @() and $null are refused outright, so the clear has exactly one
# spelling); and the read-back source is Get-ClusterOwnerNode -Group →
# .OwnerNodes → .Name. This request ships that measured surface in the exact
# image of PLG-30's failback write: identify the group first, write second,
# believe the write only when a fresh read of the cluster agrees — and refuse
# with the cluster's own words when it does not.
class UnitClusterRoleOwnerNodesWriteTest < Minitest::Test
  GUID = 'e8f37f42-5b1a-4c2d-9e6f-0a1b2c3d4e5f'

  # Same OfflineClient shape as the failback file: the request only ever
  # reaches run_cmd, so connect dials nothing and run_cmd is recorded.
  class RecordingClient < Fog::Hyperv::Compute::Real
    attr_reader :cmd_calls
    attr_accessor :stdout_to_answer

    def initialize(options)
      @cmd_calls = []
      @stdout_to_answer = ''
      super
    end

    private

    def connect(_endpoint = nil)
      @connection = Struct.new(:logger).new(Struct.new(:level).new(nil))
    end

    def run_cmd(cmd, **opts)
      @cmd_calls << [cmd, opts]
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(@stdout_to_answer, '', 0)
    end
  end

  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
    @real = RecordingClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
  end

  def teardown
    Fog.unmock!
  end

  def subject
    Fog::Hyperv::Utils::ClusterRole
  end

  def verdict(result:, wanted:, actual:, error: '', cluster_name: 'HV-CL01')
    Fog::JSON.encode(clusterName: cluster_name, result: result, error: error,
                     wanted: wanted, actual: actual)
  end

  # -- the advertised capability ------------------------------------------------

  def test_the_gem_advertises_cluster_role_owner_nodes_write
    assert_includes Fog::Hyperv::CAPABILITIES, :cluster_role_owner_nodes_write
  end

  # -- the owners argument -------------------------------------------------------

  # This is a write: nil would have to mean both "leave it alone" and "I asked
  # you to change it". The explicit [] is the caller's way of saying "no
  # restriction" — the measured unset state — and it is accepted.
  # rubocop:disable Minitest/MultipleAssertions
  def test_only_an_array_of_names_is_accepted
    assert_raises(ArgumentError) { subject.validate_owner_nodes!(nil, 'req') }
    assert_raises(ArgumentError) { subject.validate_owner_nodes!('hv-node1', 'req') }
    assert_raises(ArgumentError) { subject.validate_owner_nodes!({}, 'req') }
    assert_equal [], subject.validate_owner_nodes!([], 'req')
  end
  # rubocop:enable Minitest/MultipleAssertions

  # Node names ride the wire inside single quotes in one composed PowerShell
  # line, so each one goes through the shared host-shape rule — the same rule
  # that guards every host this gem dials. A name needing anything else has no
  # business naming a cluster node.
  def test_every_name_must_be_host_shaped
    ['', 'hv node', "hv'node", 'hv`node', '$(node)', 'hv-node*', '-hv', 'hv-.'].each do |bad|
      assert_raises(Fog::Hyperv::Errors::InvalidHostInput, "expected #{bad.inspect} to be refused") do
        subject.validate_owner_nodes!([bad], 'req')
      end
    end
    assert_equal ['hv-node1', 'HV-NODE2', 'node.example.net'],
                 subject.validate_owner_nodes!(['hv-node1', 'HV-NODE2', 'node.example.net'], 'req')
  end

  # The cluster keeps ONE entry per node and answers the read back
  # case-insensitively; a wanted list that names a node twice is a caller
  # mistake this side refuses rather than forwards a doubled -Owners array.
  def test_a_name_doubled_is_refused_whole
    assert_raises(ArgumentError) { subject.validate_owner_nodes!(%w[hv-node1 HV-NODE1], 'req') }
    assert_equal %w[hv-node1 hv-node2], subject.validate_owner_nodes!(%w[hv-node1 hv-node2], 'req')
  end

  # -- the write script -----------------------------------------------------------

  # Nothing is written on a group this side has not identified: the same triple
  # assertion the failback and removal scripts make, because Set-ClusterOwnerNode
  # lands on whatever the filter matched.
  # rubocop:disable Minitest/MultipleAssertions
  def test_the_script_identifies_the_group_before_writing_anything
    script = subject.build_owner_nodes_script(id: GUID, owner_nodes: %w[hv-node1 hv-node2])

    assert_includes script, "Get-ClusterGroup -VMId ([guid]'#{GUID}')"
    assert_includes script, 'Count -ne 1'
    assert_includes script, "GroupType -ne 'VirtualMachine'"
    assert_includes script, 'Get-FogHypervGroupVmId $group'
    assert_includes script, "-ine '#{GUID}'"
  end
  # rubocop:enable Minitest/MultipleAssertions

  # -Owners is the ONLY spelling this build binds (measured: the cmdlet has
  # Resource/Group/Owners/InputObject/Cluster — no -Nodes), and the names ride
  # as a single-quoted array in the caller's order.
  def test_the_script_writes_through_the_measured_owners_parameter
    script = subject.build_owner_nodes_script(id: GUID, owner_nodes: %w[hv-node1 hv-node2])

    assert_includes script, "Set-ClusterOwnerNode -Group $group -Owners @('hv-node1','hv-node2')"
    refute_includes script, '-Nodes'
  end

  # The clear has exactly one measured spelling: -Owners '' restores the unset
  # []. -Owners @() and $null are refused BY THE CMDLET, so the script must
  # never emit them.
  # rubocop:disable Minitest/MultipleAssertions
  def test_the_empty_list_clears_through_the_measured_empty_string
    script = subject.build_owner_nodes_script(id: GUID, owner_nodes: [])

    assert_includes script, "Set-ClusterOwnerNode -Group $group -Owners ''"
    refute_includes script, "@('')"
    refute_includes script, '-Owners @()'
    refute_includes script, '-Owners $null'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # The write is proven by the cmdlet that READS owners — Get-ClusterOwnerNode
  # asked of the same group, .OwnerNodes names into the verdict — never by the
  # object pushed.
  # rubocop:disable Minitest/MultipleAssertions
  def test_the_script_proves_the_write_by_reading_it_back
    script = subject.build_owner_nodes_script(id: GUID, owner_nodes: %w[hv-node1])

    assert_includes script, 'Get-ClusterOwnerNode -Group $group'
    assert_includes script, '$_.OwnerNodes'
    assert_includes script, "$answer['actual']"
    assert_includes script, 'applied'
    assert_includes script, 'refused'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # PSArgument from the -VMId leg is the measured "no virtual machine has this
  # id"; a write on nothing gets the named no-role verdict, unchanged.
  def test_the_script_maps_the_measured_miss_to_a_named_verdict
    script = subject.build_owner_nodes_script(id: GUID, owner_nodes: %w[hv-node1])

    assert_includes script, "'PSArgument*'"
    assert_includes script, 'no-role'
  end

  # The group is carried by the $group object inside one shell; no value read
  # from the cluster comes back through Ruby's interpolation on a later leg.
  # The only Ruby interpolations are the guarded GUID and the guarded names.
  def test_the_script_never_interpolates_remote_values_in_ruby
    script = subject.build_owner_nodes_script(id: GUID, owner_nodes: %w[hv-node1])

    assert_includes script, '-Owners @(\'hv-node1\')'
    refute_includes script, "-Name '#{GUID}'"
    refute_includes script, "-Group '#{GUID}'"
  end

  [nil, '', 'not-a-guid', '00000000-0000-0000-0000-000000000000'].each_with_index do |bad, i|
    define_method("test_the_script_refuses_an_id_that_would_unfilter_it_#{i}") do
      assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
        subject.build_owner_nodes_script(id: bad, owner_nodes: %w[hv-node1])
      end
    end
  end

  # -- the verdict parser ----------------------------------------------------------

  # applied is believed only when the fresh read-back EQUALS the wanted set —
  # order and case being the two things the cluster is measured not to preserve.
  def test_an_applied_verdict_with_an_agreeing_read_back_is_the_only_success
    assert subject.parse_owner_nodes_write(
      verdict(result: 'applied', wanted: %w[hv-node1 hv-node2], actual: %w[hv-node2 hv-node1]),
      wanted: %w[hv-node1 hv-node2]
    )
    assert subject.parse_owner_nodes_write(
      verdict(result: 'applied', wanted: %w[hv-node1], actual: ['HV-NODE1']),
      wanted: %w[hv-node1]
    )
    assert subject.parse_owner_nodes_write(
      verdict(result: 'applied', wanted: [], actual: []),
      wanted: []
    )
  end

  # A read-back that names a different set than the one written is the silent
  # no-stick this verdict exists to catch — a refused answer, not a success.
  def test_an_applied_verdict_with_a_disagreeing_read_back_is_refused
    [%w[hv-node2], %w[hv-node1 hv-node2], %w[]].each do |actual|
      assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused, "expected #{actual.inspect} refused") do
        subject.parse_owner_nodes_write(
          verdict(result: 'applied', wanted: %w[hv-node1], actual: actual),
          wanted: %w[hv-node1]
        )
      end
    end
  end

  # A null read-back means the owner read inside the shell failed — unknown,
  # and unknown is not agreement, even when the wanted set is the empty one.
  def test_a_null_read_back_never_agrees
    [%w[hv-node1], []].each do |wanted|
      assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
        subject.parse_owner_nodes_write(
          verdict(result: 'applied', wanted: wanted, actual: nil),
          wanted: wanted
        )
      end
    end
  end

  # The measured refusal text rides into the raised error so the plugin can
  # show what the cluster actually said.
  def test_a_refused_verdict_raises_with_what_the_cluster_said
    error = assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      subject.parse_owner_nodes_write(
        verdict(result: 'refused', wanted: %w[hv-node9], actual: nil,
                error: 'Server Update Failed: An internal error occurred'),
        wanted: %w[hv-node9]
      )
    end
    assert_includes error.message, 'An internal error occurred'
  end

  # A machine that is not clustered has no preferred owners to set; that is its
  # own error so the plugin can tell "not clustered" from "cluster said no".
  def test_a_roleless_machine_raises_its_own_error
    assert_raises(Fog::Hyperv::Errors::ClusterRoleNotFound) do
      subject.parse_owner_nodes_write(verdict(result: 'no-role', wanted: %w[hv-node1], actual: nil),
                                      wanted: %w[hv-node1])
    end
  end

  # Silence, garbage, and an unattributable answer are the same class of
  # non-answer the failback write and the role read already refuse.
  def test_shapes_that_cannot_be_read_are_refused
    ['', 'not json', '5',
     verdict(result: 'applied', wanted: %w[hv-node1], actual: %w[hv-node1], cluster_name: ''),
     verdict(result: 'maybe', wanted: %w[hv-node1], actual: %w[hv-node1])].each do |bad|
      assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable, "expected #{bad.inspect} to be refused") do
        subject.parse_owner_nodes_write(bad, wanted: %w[hv-node1])
      end
    end
  end

  # -- the requests -----------------------------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  def test_the_real_request_sends_the_script_to_the_writing_node
    @real.stdout_to_answer = verdict(result: 'applied', wanted: %w[hv-node2], actual: %w[hv-node2])

    assert @real.set_cluster_virtual_machine_role_owner_nodes(
      id: GUID, owner_nodes: %w[hv-node2], computer_name: 'HV-NODE2'
    )

    assert_equal 1, @real.cmd_calls.size

    cmd, opts = @real.cmd_calls.first

    assert_includes cmd, "Set-ClusterOwnerNode -Group $group -Owners @('hv-node2')"
    assert opts[:_skip_json]
    assert_equal 'HV-NODE2', opts[:_target_computer]
  end
  # rubocop:enable Minitest/MultipleAssertions

  # The guards run client-side, before anything is built or dialled.
  def test_the_real_request_refuses_a_bad_owners_list_before_the_wire
    assert_raises(ArgumentError) do
      @real.set_cluster_virtual_machine_role_owner_nodes(id: GUID, owner_nodes: nil)
    end
    assert_raises(Fog::Hyperv::Errors::InvalidHostInput) do
      @real.set_cluster_virtual_machine_role_owner_nodes(id: GUID, owner_nodes: ['bad node!'])
    end
    assert_empty @real.cmd_calls
  end

  def test_the_real_request_refuses_a_bad_id_before_the_wire
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      @real.set_cluster_virtual_machine_role_owner_nodes(id: '', owner_nodes: %w[hv-node1])
    end
    assert_empty @real.cmd_calls
  end

  def test_the_real_request_raises_when_the_cluster_refuses
    @real.stdout_to_answer = verdict(result: 'refused', wanted: %w[hv-node1], actual: %w[hv-node2],
                                     error: 'Failed to retrieve the node')

    assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      @real.set_cluster_virtual_machine_role_owner_nodes(id: GUID, owner_nodes: %w[hv-node1])
    end
  end

  # The mock mirrors the real request's answer shapes: the same guards fire, a
  # fixture machine with a role answers true the way the proven write does (for
  # the clear too), and a fixture machine without one raises the same error the
  # cluster's measured miss produces.
  # rubocop:disable Minitest/MultipleAssertions
  def test_the_mocked_client_answers_the_same_contract
    assert @client.set_cluster_virtual_machine_role_owner_nodes(
      id: '416e49fd-28dd-413c-9743-aa3e69e4807d', owner_nodes: %w[mock-node2]
    )
    assert @client.set_cluster_virtual_machine_role_owner_nodes(
      id: '416E49FD-28DD-413C-9743-AA3E69E4807D', owner_nodes: [], computer_name: 'MOCK-HOST'
    )
    assert_raises(Fog::Hyperv::Errors::ClusterRoleNotFound) do
      @client.set_cluster_virtual_machine_role_owner_nodes(
        id: '2c60b75f-6437-4b39-b156-a90538413c1b', owner_nodes: %w[mock-node1]
      )
    end
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      @client.set_cluster_virtual_machine_role_owner_nodes(id: '00000000-0000-0000-0000-000000000000',
                                                           owner_nodes: %w[mock-node1])
    end
    assert_raises(ArgumentError) do
      @client.set_cluster_virtual_machine_role_owner_nodes(id: GUID, owner_nodes: nil)
    end
  end
  # rubocop:enable Minitest/MultipleAssertions
end
