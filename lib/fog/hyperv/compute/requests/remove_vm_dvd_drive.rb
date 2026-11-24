# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    def remove_vm_dvd_drive(id:, vm_id:, computer_name: nil, **options)
      run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          ['$DVD = $VM | Get-VMDvdDrive', { _by_id: id }],
          ['$DVD | Remove-VMDvdDrive', options]
        ],
        skip_json: true,
        target_computer: computer_name
      )
    end
  end

  # Remove-VMDvdDrive takes -Passthru nowhere, and the request runs it with JSON
  # skipped, so nothing about a drive comes back and DvdDrive#destroy returns true
  # on its own. The Mock's job here is only to stop the request falling through to
  # method_missing, which raises MockNotImplemented because a mutating cmdlet has no
  # fixture of its own.
  class Mock
    def remove_vm_dvd_drive(**options)
      requires options, :id, :vm_id

      nil
    end
  end
end
