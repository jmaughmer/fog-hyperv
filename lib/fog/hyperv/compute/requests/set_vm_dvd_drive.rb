# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    def set_vm_dvd_drive(id:, vm_id:, computer_name: nil, **options)
      run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          ['$DVD = $VM | Get-VMDvdDrive', { _by_id: id }],
          ['$DVD | Set-VMDvdDrive', { passthru: true, **options }]
        ],
        target_computer: computer_name
      )
    end
  end

  # Set-VMDvdDrive is -Passthru, so its answer is the drive as it now is, and
  # DvdDrive#update merges that answer back into the model — which is how a caller
  # reads its own work. So the Mock reflects the caller's -Path rather than
  # echoing the fixture: path: nil is an eject, and an answer that still carried
  # the old file would tell iso_attach its eject had not happened.
  #
  # A drive Id the VM does not have answers nil. The Real raises PSError there,
  # because Get-VMDvdDrive -Id fails; a Mock that raised the same thing would need
  # a transport error to say "no such drive", and the callers that matter already
  # branch on nil from the read path.
  class Mock
    def set_vm_dvd_drive(**options)
      requires options, :id, :vm_id

      row = handle_mock_response(_method: 'get_vm_dvd_drive', **options).find do |candidate|
        candidate[:vm_id].casecmp(options[:vm_id].to_s).zero? &&
          candidate[:id].to_s.casecmp(options[:id].to_s).zero?
      end
      return nil unless row

      options.key?(:path) ? row.merge(path: options[:path]) : row
    end
  end
end
