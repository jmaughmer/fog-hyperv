# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    def get_vm_dvd_drive(vm_id:, computer_name: nil, **options)
      by_id = options.delete :id

      run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          ['$VM | Get-VMDvdDrive', { _by_id: by_id, **options }]
        ],
        target_computer: computer_name
      )
    end
  end

  class Mock
    def get_vm_dvd_drive(**options)
      requires options, :vm_id

      # Two defects, both on the read path a mocked DVD drive cannot get past.
      #
      # args, not options: this Mock predates the keyword conversion and read a
      # local nobody defined, so every mocked read raised NameError before it
      # looked at the fixture next door.
      #
      # The Real scopes the call with Get-VMDvdDrive -Id when the caller named a
      # drive (the model's reload passes id:, the collection's get passes the
      # _by_id: meta-argument). Filtering only by VM answered a drive the caller
      # asked away by name, so a wrong Id read as the VM's only drive.
      handle_mock_response(**options).find do |row|
        next false unless row[:vm_id].casecmp(options[:vm_id].to_s).zero?

        wanted = options[:id] || options[:_by_id]
        wanted.nil? || row[:id].to_s.casecmp(wanted.to_s).zero?
      end
    end
  end
end
