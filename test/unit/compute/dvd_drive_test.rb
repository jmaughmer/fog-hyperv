# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/compute/models/dvd_drive'

class UnitDvdDriveTest < Minitest::Test
  # The request is stood in for by a plain object with the one method on it: the
  # minitest the RPM set ships is too old for Object#stub to forward keyword
  # arguments, and the arguments are the whole point of these tests
  class FakeCompute
    attr_reader :options

    def add_vm_dvd_drive(**options)
      @options = options
      {}
    end
  end

  def test_create_sends_the_controller_it_was_given
    service = FakeCompute.new
    Fog::Hyperv::Compute::DvdDrive.new(
      service: service,
      vm_id: '9A2F1D3E-1111-2222-3333-444455556666',
      controller_number: 1,
      controller_location: 0,
      path: 'C:\images\boot.iso'
    ).create

    assert_equal 1, service.options[:controller_number]
    assert_equal 0, service.options[:controller_location]
  end

  # The typo this was written for read controller_numbere, so the drive was built
  # on a controller nobody had asked for
  def test_create_sends_no_option_of_that_name
    service = FakeCompute.new
    Fog::Hyperv::Compute::DvdDrive.new(
      service: service,
      vm_id: '9A2F1D3E-1111-2222-3333-444455556666',
      controller_number: 1,
      path: 'C:\images\boot.iso'
    ).create

    assert_empty service.options.keys.grep(/numbere/)
  end
end
