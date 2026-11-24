# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    def add_vm_dvd_drive(vm_id:, computer_name: nil, **options)
      run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          ['$VM | Add-VMDvdDrive', { passthru: true, **options }]
        ],
        target_computer: computer_name
      )
    end
  end

  # Add-VMDvdDrive is -Passthru, so its answer is the drive it made. The fixture
  # the read path uses already carries that shape, which is why this reads it
  # instead of growing a near-identical JSON file of its own: a second copy would
  # be free to disagree with the read about what a drive looks like.
  #
  # The drive it hands back has no media, which is what Add-VMDvdDrive without
  # -Path produces on the lab node: the drive appears (COUNT=1) with an Id, and
  # Set-VMDvdDrive is what puts a file in it. Whether Add-VMDvdDrive -Path
  # answers the new drive already holding its file was never measured here, so
  # the Mock invents nothing for that either: the fixture drive comes back
  # unchanged and a caller that needs the after state re-reads, the rule every
  # other Mocked drive answer follows. The Id is the fixture drive's rather
  # than a freshly minted GUID: a Mock that invented one would hand the caller an
  # identity no host recognises, which is worse than reusing one it can follow up.
  class Mock
    def add_vm_dvd_drive(**options)
      requires options, :vm_id

      handle_mock_response(_method: 'get_vm_dvd_drive', **options)
        .find { |row| row[:vm_id].casecmp(options[:vm_id].to_s).zero? }
    end
  end
end
