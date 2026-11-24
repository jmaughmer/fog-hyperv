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

  # Set-VMDvdDrive is -Passthru, and the lab measured what that answer really
  # is: the drive as it was BEFORE the change (an eject answered the file the
  # eject had just released, while the next fresh read of the same drive already
  # answered it gone — BD-EJ3-REQUEST-ANSWER vs BD-EJ3-GET-AFTER). So the Mock
  # answers the fixture drive unchanged, and DvdDrive#update does not merge that
  # answer either — merging the pre-change drive (and resetting @old from it,
  # which merge_attributes does) is what made a following eject look unchanged.
  # The model re-reads the drive instead, which is the only host answer that
  # describes the write. The Mock used to "reflect the caller's -Path" instead,
  # a politeness no real host makes.
  #
  # A drive Id the VM does not have answers nil. The Real raises there: the Id
  # filter is a Where-Object over Get-VMDvdDrive rather than a -Id the cmdlet
  # answers itself, so a drive the VM does not have leaves $DVD null and the
  # piped Set-VMDvdDrive fails binding that null input under Stop. A Mock that
  # raised the same thing would need a transport error to say "no such drive",
  # and the callers that matter already branch on nil from the read path.
  class Mock
    def set_vm_dvd_drive(**options)
      requires options, :id, :vm_id

      handle_mock_response(_method: 'get_vm_dvd_drive', **options).find do |candidate|
        candidate[:vm_id].casecmp(options[:vm_id].to_s).zero? &&
          candidate[:id].to_s.casecmp(options[:id].to_s).zero?
      end
    end
  end
end
