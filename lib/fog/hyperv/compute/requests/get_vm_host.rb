# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    def get_vm_host(computer_name: nil, **options)
      run_cmd 'Get-VMHost', _target_computer: computer_name, **options
    end
  end

  class Mock
    # Get-VMHost has no name filter to honour: -ComputerName says which machine the
    # call runs against, and that machine answers with itself. So a mocked call that
    # names a machine answers with that one entry only, which is what a cluster
    # asking after each of its nodes needs — otherwise every node answers with the
    # first host in the fixture and a two-node cluster looks like one host twice.
    def get_vm_host(**args)
      data = handle_mock_response(**args)
      name = args[:computer_name] || args[:name]
      data = data.select { |host| host[:name].casecmp(name.to_s).zero? } if name
      data
    end
  end
end
