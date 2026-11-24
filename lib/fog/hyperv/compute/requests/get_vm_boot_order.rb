# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/boot_order'

    # Read a Gen2 VM's UEFI boot order as an ordered list of flat entries.
    #
    #   get_vm_boot_order(vm_id: '1c51c4ee-...', computer_name: 'hv-node2')
    #   # => [{ position: 1, boot_type: 'Drive',
    #          device_text: 'HardDiskDrive (Name = disk.vhdx)',
    #          device_id: 'Microsoft:...', firmware_path: '' }, ...]
    #
    # device_text is the rendering of the entry's Device — the measured shape
    # spike 0.4 classified on ("VMNetworkAdapter (Name = ...)", "HardDiskDrive
    # (Name = ...)") — and firmware_path is the File entry's payload, whose
    # Device is null. Those two plus device_id are everything
    # set_vm_boot_order's contract needs to reason about an order without
    # re-deriving classes from prose.
    #
    # A Gen1 VM refuses on its own: Get-VMFirmware errors there and the
    # transport runs with $ErrorActionPreference=Stop, so the caller gets a
    # PSError naming the cmdlet's Gen 1 complaint.
    #
    # No Mock of its own, like remove_file: the boot-order seam calls this
    # request and reads its answer through the request's own contract (the
    # rows are script-rendered JSON decoded by BootOrder.decode, a shape no
    # mock_files fixture in this fork carries), and a fixture that invented one
    # would be free to disagree with what the script actually prints.
    def get_vm_boot_order(vm_id:, computer_name: nil, **_options)
      out = run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          [Fog::Hyperv::Utils::BootOrder.build_read_script, {}]
        ],
        skip_json: true,
        target_computer: computer_name
      )

      Fog::Hyperv::Utils::BootOrder.decode(out)
    end
  end
end
