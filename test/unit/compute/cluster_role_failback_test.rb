# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/requests/set_cluster_virtual_machine_role_auto_failback'

# PLG-30: the one per-role High Availability setting this cluster build accepts
# as a WRITE is automatic failback — measured on HV-CL01 (evidence section 60)
# by setting $group.AutoFailbackType, reading it back, and restoring it, twice.
# Priority, the failback window, and preferred owners are refused or no-op on
# VM-role groups under the bound identity, so they stay read-only here, and
# this whole contract — script, verdict, errors — exists to make even the one
# writable knob refuse rather than pretend.
class UnitClusterRoleFailbackTest < Minitest::Test
  GUID = 'e8f37f42-5b1a-4c2d-9e6f-0a1b2c3d4e5f'

  # Fog::Hyperv::Compute::Real dials WinRM on initialize; this request only
  # ever reaches run_cmd, so connect dials nothing and run_cmd is recorded —
  # the OfflineClient shape FOG-11 established, answering canned stdout.
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

  def verdict(result:, wanted: 1, actual: nil, error: '', cluster_name: 'HV-CL01')
    Fog::JSON.encode(clusterName: cluster_name, result: result, error: error,
                     wanted: wanted, actual: actual)
  end

  # -- the advertised capability ----------------------------------------------

  # A plugin on an older gem must be able to ask whether this contract exists
  # before calling it, the way every other fork behaviour is gated.
  def test_the_gem_advertises_cluster_role_failback
    assert_includes Fog::Hyperv::CAPABILITIES, :cluster_role_failback
  end

  # -- the role read grows the HA properties -----------------------------------

  # The Registration cell will display failback state, and reading these
  # properties costs one field each in the shell that already enumerates the
  # groups (measured readable even where the writes are refused).
  def test_the_read_script_carries_the_failback_properties
    script = subject.build_read_script(vm_id: GUID)

    assert_includes script, 'autoFailbackType = $group.AutoFailbackType'
    assert_includes script, 'failbackWindowStart = $group.FailbackWindowStart'
    assert_includes script, 'failbackWindowEnd = $group.FailbackWindowEnd'
  end

  # The fixture mirrors the real read's answer shape, so the model fields have
  # to arrive through the mocked read exactly as they do through the script.
  def test_a_mocked_role_reports_its_failback_state
    role = @client.clusters.first.roles.detect do |r|
      r.virtual_machine_id.to_s.casecmp('416e49fd-28dd-413c-9743-aa3e69e4807d').zero?
    end

    assert_equal 0, role[:auto_failback_type]
    assert_equal false, role.auto_failback
    # 4294967295..4294967295 is the measured answer of a cluster with no
    # failback window; it means "off", not "a window at minute 4.2 billion".
    assert_nil role.failback_window
  end

  def test_the_model_reads_the_measured_sentinel_and_the_reported_pair
    on = Fog::Hyperv::Compute::ClusterVirtualMachineRole.new(
      auto_failback_type: 1, failback_window_start: 1500, failback_window_end: 2400
    )
    assert_equal true, on.auto_failback
    assert_equal [1500, 2400], on.failback_window

    off = Fog::Hyperv::Compute::ClusterVirtualMachineRole.new(
      auto_failback_type: 0, failback_window_start: 4_294_967_295, failback_window_end: 4_294_967_295
    )
    assert_equal false, off.auto_failback
    assert_nil off.failback_window

    # A role that never reported the property answers "I do not know", not
    # "failback is off" — the same refusal-not-guessing rule as the reads.
    unknown = Fog::Hyperv::Compute::ClusterVirtualMachineRole.new(name: 'Virtual Machine x')
    assert_nil unknown.auto_failback
    assert_nil unknown.failback_window
  end

  # -- the write script ---------------------------------------------------------

  # Nothing is written on a name this side has not identified: the same triple
  # assertion the removal script makes before deleting, because the property is
  # set on whatever group the filter matched.
  def test_the_failback_script_identifies_the_group_before_writing_anything
    script = subject.build_failback_script(id: GUID, enabled: true)

    assert_includes script, "Get-ClusterGroup -VMId ([guid]'#{GUID}')"
    assert_includes script, 'Count -ne 1'
    assert_includes script, "GroupType -ne 'VirtualMachine'"
    assert_includes script, 'Get-FogHypervGroupVmId $group'
    assert_includes script, "-ine '#{GUID}'"
    assert_includes script, '$group.AutoFailbackType = 1'
  end

  def test_false_means_the_type_the_cluster_uses_for_off
    script = subject.build_failback_script(id: GUID, enabled: false)

    assert_includes script, '$group.AutoFailbackType = 0'
    refute_includes script, '$group.AutoFailbackType = 1'
  end

  # The write is proven by a fresh read, not by the object that was pushed:
  # a property set can answer success and not stick (the Priority refusal was
  # only loud because it threw; a silent no-stick must not read as applied).
  def test_the_failback_script_proves_the_write_by_reading_it_back
    script = subject.build_failback_script(id: GUID, enabled: true)

    assert_includes script, 'Get-ClusterGroup -Name $group.Name'
    assert_includes script, "$answer['actual']"
    assert_includes script, 'applied'
    assert_includes script, 'refused'
  end

  # PSArgument from the -VMId leg is the measured "no virtual machine has this
  # id"; it becomes a named no-role verdict, not an exception shape the parser
  # would have to guess about.
  def test_the_failback_script_maps_the_measured_miss_to_a_named_verdict
    script = subject.build_failback_script(id: GUID, enabled: true)

    assert_includes script, "'PSArgument*'"
    assert_includes script, 'no-role'
  end

  # The remote group name is only ever used remotely ($group.Name inside the
  # script); nothing read from the cluster comes back through Ruby's
  # interpolation on a later leg.
  def test_the_failback_script_never_interpolates_remote_values_in_ruby
    script = subject.build_failback_script(id: GUID, enabled: true)

    assert_includes script, '-Name $group.Name'
    refute_includes script, "-Name '#{GUID}'"
  end

  [nil, '', 'not-a-guid', '00000000-0000-0000-0000-000000000000'].each_with_index do |bad, i|
    define_method("test_the_failback_script_refuses_an_id_that_would_unfilter_it_#{i}") do
      assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
        subject.build_failback_script(id: bad, enabled: true)
      end
    end
  end

  # -- the verdict parser -------------------------------------------------------

  def test_an_applied_verdict_is_the_only_success
    assert_equal true, subject.parse_failback_write(verdict(result: 'applied', actual: 1), wanted: 1)
    assert_equal true, subject.parse_failback_write(verdict(result: 'applied', wanted: 0, actual: 0), wanted: 0)
  end

  # The measured refusal text rides into the raised error so the plugin can
  # show what the cluster actually said.
  def test_a_refused_verdict_raises_with_what_the_cluster_said
    error = assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      subject.parse_failback_write(
        verdict(result: 'refused', error: 'Unable to save property changes'), wanted: 1
      )
    end
    assert_includes error.message, 'Unable to save property changes'
  end

  # Defence in depth: 'applied' is believed only while the read-back value
  # agrees with what was asked; a verdict that contradicts itself is refused.
  def test_a_verdict_that_contradicts_itself_is_refused
    assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      subject.parse_failback_write(verdict(result: 'applied', wanted: 1, actual: 0), wanted: 1)
    end
    assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      subject.parse_failback_write(verdict(result: 'applied', wanted: 1, actual: nil), wanted: 1)
    end
  end

  # A machine that is not clustered has no failback to set; that is its own
  # error so the plugin can tell "not clustered" apart from "cluster said no".
  def test_a_roleless_machine_raises_its_own_error
    assert_raises(Fog::Hyperv::Errors::ClusterRoleNotFound) do
      subject.parse_failback_write(verdict(result: 'no-role', actual: nil), wanted: 1)
    end
  end

  # Silence, garbage, and an unattributable answer are the same class of
  # non-answer the role read already refuses: shapes the code will not guess.
  def test_shapes_that_cannot_be_read_are_refused
    ['', 'not json', '5',
     verdict(result: 'applied', actual: 1, cluster_name: ''),
     verdict(result: 'maybe', actual: 1)].each do |bad|
      assert_raises(Fog::Hyperv::Errors::RoleReadUninterpretable, "expected #{bad.inspect} to be refused") do
        subject.parse_failback_write(bad, wanted: 1)
      end
    end
  end

  # -- the requests --------------------------------------------------------------

  def test_the_real_request_sends_the_script_to_the_writing_node
    @real.stdout_to_answer = verdict(result: 'applied', actual: 1)

    assert_equal true, @real.set_cluster_virtual_machine_role_auto_failback(
      id: GUID, auto_failback: true, computer_name: 'HV-NODE2'
    )

    assert_equal 1, @real.cmd_calls.size
    cmd, opts = @real.cmd_calls.first
    assert_includes cmd, '$group.AutoFailbackType = 1'
    assert_equal true, opts[:_skip_json]
    assert_equal 'HV-NODE2', opts[:_target_computer]
  end

  # The boolean is the whole contract; nil and truthy-lookalikes are refused
  # client-side because "auto_failback: nil" cannot mean both "off" and "not
  # specified" when the call is a write.
  def test_the_real_request_refuses_a_non_boolean_before_the_wire
    [nil, 'yes', 1, 0].each do |bad|
      assert_raises(ArgumentError, "expected #{bad.inspect} to be refused") do
        @real.set_cluster_virtual_machine_role_auto_failback(id: GUID, auto_failback: bad)
      end
    end
    assert_empty @real.cmd_calls
  end

  def test_the_real_request_refuses_a_bad_id_before_the_wire
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      @real.set_cluster_virtual_machine_role_auto_failback(id: '', auto_failback: true)
    end
    assert_empty @real.cmd_calls
  end

  def test_the_real_request_raises_when_the_cluster_refuses
    @real.stdout_to_answer = verdict(result: 'refused', error: 'Unable to save property changes')

    assert_raises(Fog::Hyperv::Errors::RolePropertyWriteRefused) do
      @real.set_cluster_virtual_machine_role_auto_failback(id: GUID, auto_failback: true)
    end
  end

  # The mock mirrors the real request's answer shapes: the same guards fire, a
  # fixture machine answers true, and a machine the fixture has no role for
  # raises the same error the cluster's own miss would.
  def test_the_mocked_client_answers_the_same_contract
    assert_equal true, @client.set_cluster_virtual_machine_role_auto_failback(
      id: '416e49fd-28dd-413c-9743-aa3e69e4807d', auto_failback: true
    )
    assert_equal true, @client.set_cluster_virtual_machine_role_auto_failback(
      id: '416E49FD-28DD-413C-9743-AA3E69E4807D', auto_failback: false, computer_name: 'MOCK-HOST'
    )
    assert_raises(Fog::Hyperv::Errors::ClusterRoleNotFound) do
      @client.set_cluster_virtual_machine_role_auto_failback(
        id: '2c60b75f-6437-4b39-b156-a90538413c1b', auto_failback: true
      )
    end
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      @client.set_cluster_virtual_machine_role_auto_failback(id: '00000000-0000-0000-0000-000000000000',
                                                             auto_failback: true)
    end
    assert_raises(ArgumentError) do
      @client.set_cluster_virtual_machine_role_auto_failback(id: GUID, auto_failback: nil)
    end
  end
end
