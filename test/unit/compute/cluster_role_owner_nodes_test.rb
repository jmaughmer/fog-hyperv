# frozen_string_literal: true

require 'test_helper'

# PLG-31b: the cluster's preferred owners for a role — the nodes it PREFERS
# to run the machine on — make the same trip into the role read as PLG-30's
# failback properties did, so the VM detail page can show what Failover
# Cluster Manager's Owners tab shows without a second round trip.
#
# Everything here is pinned to the measured build (evidence section 76),
# which overturned the fixture's story: PreferredNodeNames is NOT a
# ClusterGroup property (it answers $null); the cmdlet is
# Get-ClusterOwnerNode -Group, whose objects carry ClusterObject + OwnerNodes
# (not the documented Group/Owners); the bare unfiltered call answers nothing
# at all, so every group must be asked individually (measured 16 ms each);
# and the UNSET state reads back [] — the cluster's positive "no restricted
# list, any node may own" answer. A failed per-group owner read therefore
# stays $null: display must never claim "no restriction" from a read that
# failed, the same refusal-not-guessing rule every other field follows.
class UnitClusterRoleOwnerNodesTest < Minitest::Test
  GUID = 'e8f37f42-5b1a-4c2d-9e6f-0a1b2c3d4e5f'
  MOCKVM1 = '416e49fd-28dd-413c-9743-aa3e69e4807d'
  MOCKVM2 = '20ff7fe3-fd54-425c-aa97-fbf3c2e7a868'

  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
  end

  def teardown
    Fog.unmock!
  end

  def subject
    Fog::Hyperv::Utils::ClusterRole
  end

  def envelope(rows:, cluster_name: 'HV-CL01')
    Fog::JSON.encode(clusterName: cluster_name, miss: '', roles: rows)
  end

  def row(**extra)
    { name: 'role-vm', groupType: 'VirtualMachine', vmId: GUID, ownerNode: 'hv-node2',
      state: 2, priority: 0 }.merge(extra)
  end

  # -- the advertised capability ----------------------------------------------

  # The plugin gates the new display on this constant so an older gem renders
  # the section in silence instead of claiming Unknown for a field that
  # contract never had.
  def test_the_gem_advertises_cluster_role_owner_nodes
    assert_includes Fog::Hyperv::CAPABILITIES, :cluster_role_owner_nodes
  end

  # -- the read script grows the owner list ------------------------------------

  # Measured shape first: the source is Get-ClusterOwnerNode -Group, per
  # group, because the bare call answers nothing and the group object carries
  # no PreferredNodeNames to read off. The projected string is the node's
  # .Name — the one member of a ClusterNode that names it as the cluster
  # names nodes everywhere else.
  # rubocop:disable Minitest/MultipleAssertions
  def test_the_read_script_asks_each_group_for_its_owner_nodes
    script = subject.build_read_script(vm_id: GUID)

    assert_includes script, 'Get-ClusterOwnerNode -Group $group',
                    'the measured source is the per-group cmdlet, not the null group property'
    assert_includes script, 'OwnerNodes',
                    'this build answers OwnerNodes, not the documented Owners pair'
    assert_includes script, '[string]$_.Name',
                    'the readable name is the ClusterNode Name, projected to string'
    assert_includes script, 'preferredNodeNames = $preferredOwners'
  end

  # The unset [] is a POSITIVE answer ("any node may own"), so a failed read
  # must not arrive as []: the variable starts null and the catch restores
  # null, and the two $null assignments are what keeps those two answers
  # distinguishable at the far end.
  def test_a_failed_owner_read_stays_unknown_and_never_becomes_unset
    script = subject.build_read_script(vm_id: GUID)

    assert_equal 2, script.scan('$preferredOwners = $null').size,
                 'null initialization and null catch: unknown must not collapse into the unset []'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # -- the parser passes the three states through ------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  def test_the_three_owner_states_survive_the_parser_apart
    restricted = subject.parse_role_read(
      envelope(rows: [row(preferredNodeNames: %w[hv-node1 hv-node3])])
    ).first
    unset = subject.parse_role_read(envelope(rows: [row(preferredNodeNames: [])])).first
    unknown = subject.parse_role_read(envelope(rows: [row(preferredNodeNames: nil)])).first
    absent = subject.parse_role_read(envelope(rows: [row])).first

    assert_equal %w[hv-node1 hv-node3], restricted[:preferred_node_names]
    # Exactly []: nil here would read the cluster's "no restricted list"
    # answer as "the field never arrived".
    assert_equal [], unset[:preferred_node_names]
    assert_nil unknown[:preferred_node_names]
    assert_nil absent[:preferred_node_names]
  end
  # rubocop:enable Minitest/MultipleAssertions

  # -- the model carries it verbatim --------------------------------------------

  # No interpretation on this side: [] and nil are different claims about the
  # cluster and only the display layer is allowed to label them.
  def test_the_model_reports_preferred_node_names_verbatim
    restricted = Fog::Hyperv::Compute::ClusterVirtualMachineRole.new(preferred_node_names: %w[hv-node1])
    unset = Fog::Hyperv::Compute::ClusterVirtualMachineRole.new(preferred_node_names: [])
    unknown = Fog::Hyperv::Compute::ClusterVirtualMachineRole.new(name: 'Virtual Machine x')

    assert_equal ['hv-node1'], restricted.preferred_node_names
    assert_equal [], unset.preferred_node_names
    assert_nil unknown.preferred_node_names
  end

  # -- the fixture mirrors the real read's answer shapes -------------------------

  # mockvm1 carries the unset [] and mockvm2 a restricted one-node list, so
  # both real states have a mocked counterpart a plugin test can lean on.
  def test_a_mocked_role_reports_its_owner_list
    roles = @client.clusters.first.roles
    first = roles.detect { |r| r.virtual_machine_id.to_s.casecmp(MOCKVM1).zero? }
    second = roles.detect { |r| r.virtual_machine_id.to_s.casecmp(MOCKVM2).zero? }

    assert_equal [], first.preferred_node_names
    assert_equal ['mock-node2'], second.preferred_node_names
  end
end
