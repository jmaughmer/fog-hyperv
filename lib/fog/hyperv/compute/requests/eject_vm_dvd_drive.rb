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
    # -Passthru is for the caller that wants the drive object; measured on the
    # lab node, that answer is the drive as it was BEFORE the eject (the file the
    # eject had just released rode back in it), so a caller that needs the after
    # state re-reads the drive. The _always_include is not decoration: a nil
    # argument is what the transport's arg filter drops, and a dropped Path
    # silently turns the eject into a no-op that passes the still-mounted drive
    # back — the PR-1 lab measurement saw exactly that answer from the real host.
    # Claiming the key carries the nil into the rendered parameters, where it
    # binds as -Path $null, which is the eject. A drive Id the VM does not have
    # leaves $DVD null — the Id filter is a Where-Object over Get-VMDvdDrive,
    # not a -Id the cmdlet answers — and the piped Set-VMDvdDrive then fails
    # binding that null input under Stop. That is the honest refusal: eject
    # "this drive" on a VM that never had it is a caller error, not something
    # to answer as already-done.
    def eject_vm_dvd_drive(id:, vm_id:, computer_name: nil, **_options)
      run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          ['$DVD = $VM | Get-VMDvdDrive', { _by_id: id }],
          ['$DVD | Set-VMDvdDrive', { _always_include: %i[path], passthru: true, path: nil }]
        ],
        target_computer: computer_name
      )
    end
  end

  # The eject is a set with a fixed -Path $null, so the Mock is the set's Mock:
  # it answers the fixture drive as it was before the change, which is what the
  # lab measured the real Passthru answer to be. A caller that needs to know the
  # media actually left re-reads the drive — under Mock that is the fixture too,
  # and a drive Id the fixture does not carry answers nil like the set's does.
  class Mock
    def eject_vm_dvd_drive(**options)
      requires options, :id, :vm_id

      set_vm_dvd_drive(**options, path: nil)
    end
  end
end
