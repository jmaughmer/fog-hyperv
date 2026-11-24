# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/boot_order'

    # Put the named classes at the front of a Gen2 VM's UEFI boot order,
    # keeping every other entry that was already in it, in one write.
    #
    #   set_vm_boot_order(vm_id: '1c51c4ee-...',
    #                     order: ['HardDiskDrive', { 'DvdDrive' => drive_id }, 'VMNetworkAdapter'])
    #
    # Each element is a class name from Fog::Hyperv::Utils::BootOrder::REQUESTABLE
    # or, for DvdDrive only, a Class => Id pair naming one drive. A class names
    # its whole group: every entry of that class moves together, relative order
    # preserved, because an order that lists one of two NICs drops the others
    # out of the firmware's list entirely — measured, spike 0.4, where a subset
    # write deleted this lab VM's hard drive from its own boot order.
    # HardDiskDrive and VMNetworkAdapter therefore refuse an Id (which of the
    # group is "the" one is a caller decision fog will not guess); DvdDrive is
    # the class the bootdisk seam addresses through a specific drive.
    #
    # The script behind this reads the current order, computes the full
    # expected sequence, writes it with ONE Set-VMFirmware -BootOrder (no
    # -FirstBootDevice: the spike measured that -BootOrder alone accepts and
    # places even a freshly fetched device object), then reads back the complete
    # ordered identity sequence. "Already present" is decided by comparing the
    # requested Id against each entry's Device.Id, never by object reference —
    # a fresh device object never reference-equals a boot entry's Device, and
    # reference matching is how a retry duplicates an entry. If the read-back
    # disagrees, the script writes back the order it captured before the
    # attempt and raises, so a failed call leaves the VM bootable, not
    # half-reordered.
    #
    # Refusals before any traffic: an unknown or repeated class, an empty
    # order, a non-DVD class named by Id. Refusals from the script: a named
    # DvdDrive the VM does not have, or a requested class with no device on the
    # VM to place. A Gen1 VM errors from Get-VMFirmware itself. Answers the new
    # order in get_vm_boot_order's shape. No Mock, like remove_file.
    def set_vm_boot_order(vm_id:, order:, computer_name: nil, **_options)
      requests = Fog::Hyperv::Utils::BootOrder.normalize(order)

      out = run_cmdlist(
        [
          ['$VM = Get-VM', { id: vm_id }],
          [Fog::Hyperv::Utils::BootOrder.build_set_script(requests), {}]
        ],
        skip_json: true,
        target_computer: computer_name
      )

      Fog::Hyperv::Utils::BootOrder.decode(out)
    end
  end
end
