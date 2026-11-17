# frozen_string_literal: true

require 'test_helper'

# Most requests have no Mock of their own: Fog::Hyperv::Compute::Mock answers them
# through method_missing, from mock_files/<request>.json. That path was passing the
# arguments along as a positional Hash to a method that takes keywords, so every one
# of those requests raised "wrong number of arguments (given 1, expected 0)" under
# Fog.mock! — including the ones the cluster models go through.
class UnitMockTest < Minitest::Test
  def setup
    Fog.mock!
    @client = Fog::Compute.new(provider: 'hyperv', hyperv_username: 'test')
  end

  def teardown
    Fog.unmock!
  end

  # Get-VMHost has no Mock implementation, only a fixture
  def test_a_request_without_a_mock_of_its_own_answers_from_its_fixture
    host = @client.hosts.first

    assert_equal 'MOCK-HOST', host.name
    assert_equal 'C:\\Hyper-V', host.virtual_machine_path
  end

  # _return_fields is what the collections ask for: Get-VMHost's fixture carries far
  # more properties than the model declares, and the mock has to slice them or a
  # model ends up holding fields nobody declared
  def test_the_fixture_is_cut_down_to_the_requested_fields
    host = @client.hosts.first
    declared = Fog::Hyperv::Compute::Host.attributes

    assert_includes host.attributes.keys, :name
    refute_includes host.attributes.keys, :fibre_channel_wwnn
    assert host.attributes.keys.all? { |field| declared.include?(field) }
  end

  def test_an_unknown_request_still_raises_no_method_error
    assert_raises NoMethodError do
      @client.this_request_does_not_exist
    end
  end

  # Get-VMHost has no name filter: -ComputerName says which machine the call runs
  # against, and that machine answers with itself. A cluster asking after each of its
  # nodes in turn depends on that, or a two-node cluster reads as one host twice.
  def test_a_host_asked_about_by_name_answers_for_that_machine_only
    assert_equal ['MOCK-HOST', 'MOCK-NODE2'], @client.hosts.all.map(&:name)
    assert_equal 'MOCK-NODE2', @client.hosts.get('MOCK-NODE2').name
    assert_equal 'MOCK-NODE2', @client.hosts.get('mock-node2').name
    assert_equal 'C:\\ClusterStorage\\Volume1\\VirtualHardDisks',
                 @client.hosts.get('MOCK-NODE2').virtual_hard_disk_path
    assert_raises(Fog::Errors::NotFound) { @client.hosts.get('MOCK-NODE3') }
  end
end
