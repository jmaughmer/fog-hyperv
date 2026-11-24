# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # Take the media out of one DVD drive, addressed by its Id.
    #
    #   eject_vm_dvd_drive(vm_id: '1c51c4ee-...', id: 'Microsoft:416E49FD-...\\0\\1\\D')
    #
    # Its own request rather than a set_vm_dvd_drive call the caller assembles,
    # because ejecting is a different promise: Set-VMDvdDrive -Path $null on an
    # already-ejected drive succeeds and changes nothing, so a detach task that
    # retries after a partial failure (or after the host dropped the media on its
    # own) gets the same clean answer a second time. The request therefore reads
    # nothing about the drive's current state first — an existence or media check
    # would turn that retry into a false failure — and it names the drive by Id
    # rather than taking "the first drive", which is the same addressing rule
    # every other drive-scoped request here follows.
    #
    # -Passthru, like set_vm_dvd_drive: the answer is the drive as it now is, with
    # path nil. A drive Id the VM does not have raises from Get-VMDvdDrive -Id,
    # which is the honest refusal: eject "this drive" on a VM that never had it
    # is a caller error, not something to answer as already-done.
    def eject_vm_dvd_drive(id:, vm_id:, computer_name: nil, **_options)
      run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          ['$DVD = $VM | Get-VMDvdDrive', { _by_id: id }],
          ['$DVD | Set-VMDvdDrive', { passthru: true, path: nil }]
        ],
        target_computer: computer_name
      )
    end
  end

  # The eject is a set with a fixed -Path $null, so the Mock says exactly that:
  # it answers the fixture drive with the media gone (the same merge-back shape
  # set_vm_dvd_drive's Mock documents — an answer still carrying the old file
  # would tell a retried detach its eject had not happened), and a drive Id the
  # fixture does not carry answers nil like the set's does.
  class Mock
    def eject_vm_dvd_drive(**options)
      requires options, :id, :vm_id

      set_vm_dvd_drive(**options, path: nil)
    end
  end
end
