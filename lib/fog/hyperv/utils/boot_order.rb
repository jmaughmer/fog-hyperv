# frozen_string_literal: true

module Fog::Hyperv
  module Utils
    # The UEFI boot-order scripts behind get_vm_boot_order / set_vm_boot_order.
    #
    # Spike 0.4 measured the two failure modes these scripts exist to avoid. One:
    # Set-VMFirmware -BootOrder replaces the whole order, so writing only the
    # devices a caller cares about silently deletes everything else — on the lab
    # VM that wrote the hard drive out of its own boot order (the read-back came
    # back N=1). Two: a device object fetched fresh does not reference-equal the
    # Device inside a boot entry, so "is it already in the order" has to compare
    # identifiers, and the only stable one is the device Id.
    #
    # So every script here classifies entries by BootType first and device class
    # second (a File entry's Device is null: its rendering is empty, and a
    # classifier keyed on the rendering alone would put the installer's own File
    # entries in no class at all), matches requested devices by .Device.Id, and —
    # in the write script — restores the captured original and raises when the
    # read-back disagrees, so a failed attempt never leaves the VM half-reordered.
    module BootOrder
      # Classes a caller may request. They are the tokens the device rendering
      # shows ("HardDiskDrive (Name = ...)"), measured for hard drives and
      # network adapters in spike 0.4, and the PR-1 lab measurement settled the
      # third: a DVD boot entry renders its Device as DvdDrive, NOT the
      # cmdlet-family DVDDrive. The measurement also caught the classifier: a
      # NIC entry answers BootType 'Network', so a classifier keyed on BootType
      # first never matched the requested VMNetworkAdapter, the fetch branch
      # added the same adapter again, and Set-VMFirmware refused the duplicate
      # with WMI's Element not found (0x80070490) — on the host, twice. A fog
      # class token is what fog-class prints, and fog-class keys on the Device
      # rendering because it is the only string naming the class; a token that
      # does not equal fog-class output is not a no-op, it is a duplicate. File
      # and EFI entries are preserved but not requestable: a File boot entry is
      # a firmware path, not a device this API addresses.
      REQUESTABLE = %w[HardDiskDrive DvdDrive VMNetworkAdapter].freeze

      # Decode a script's own ConvertTo-Json body the way the transport decodes
      # the answers it parses: uncamelized, symbol-keyed rows. The boot-order
      # scripts render JSON themselves (the batch has to end in one render no
      # matter which branch wrote it), so the batch runs with the transport's
      # JSON skipped and the shape rules live here instead.
      def self.decode(out)
        body = out.stdout.to_s.strip
        return [] if body.empty?

        Fog::Hyperv.uncamelize(Fog::JSON.decode(body))
      end

      # Validate and normalize a caller's boot-order request before any traffic:
      # what the host could not honour anyway should not reach the host. The
      # shape rules mirror the script's: whole groups (a named Id only for
      # DvdDrive), one mention of a class (a repeat would reorder the first
      # group it matched and then insert a second copy), and at least one entry
      # (an empty order would write the VM's boot order down to nothing).
      def self.normalize(order)
        raise ArgumentError, 'order must be a non-empty Array of boot classes' unless order.is_a?(Array) && order.any?

        entries = order.map do |element|
          case element
          when String, Symbol
            [element.to_s, nil]
          when Hash
            raise ArgumentError, "each order entry is a class name or one 'Class' => id pair: #{element.inspect}" unless element.size == 1

            klass, id = element.first
            [klass.to_s, id]
          else
            raise ArgumentError, "each order entry is a class name or one 'Class' => id pair: #{element.inspect}"
          end
        end

        names = entries.map(&:first)
        unknown = names - REQUESTABLE
        raise ArgumentError, "unknown boot order class #{unknown.first.inspect}; requestable: #{REQUESTABLE.join(', ')}" if unknown.any?

        repeated = names.tally.find { |_, count| count > 1 }
        raise ArgumentError, "order repeats #{repeated[0]}" if repeated

        entries.map do |klass, id|
          if !id.nil? && klass != 'DvdDrive'
            raise ArgumentError, "#{klass} moves as a whole group and cannot be named by Id; only DvdDrive can"
          end

          { 'Class' => klass, 'Id' => id }
        end
      end

      class << self
        # Identity of a boot entry or a bare device, as one string. For an entry:
        # the FirmwarePath for File, the Device's Id for anything with a Device.
        # For a device object fetched outside the order: its own Id. The write
        # script compares want/got sequences built through this same function on
        # both sides, so the two sides cannot disagree by construction.
        def identity_functions
          <<~SCRIPT
            function fog-class {
              param($e)
              if ($e.PSObject.Properties.Name -contains 'BootType') {
                $fogT = ("$($e.Device)" -split ' ')[0]
                if ($fogT) { $fogT } else { "$($e.BootType)" }
              } else {
                "$($e)"
              }
            }
            function fog-id {
              param($x)
              if ($x.PSObject.Properties.Name -contains 'BootType') {
                if ($x.BootType -eq 'File') { "$($x.FirmwarePath)" }
                elseif ($null -ne $x.Device) { "$($x.Device.Id)" }
                else { '' }
              } else {
                "$($x.Id)"
              }
            }
          SCRIPT
        end

        def rows_render
          <<~SCRIPT
            $fogI = 0
            ConvertTo-Json -Compress -InputObject @(foreach ($fogE in $fogBoot) {
              $fogI++
              [PSCustomObject]@{
                Position     = $fogI
                BootType     = "$($fogE.BootType)"
                DeviceText   = "$($fogE.Device)"
                DeviceId     = (fog-id $fogE)
                FirmwarePath = "$($fogE.FirmwarePath)"
              }
            })
          SCRIPT
        end

        # Read the current UEFI boot order as an ordered, flat list. Gen1 refuses
        # on its own: Get-VMFirmware errors there, and $ErrorActionPreference is
        # Stop, so the caller gets a PSError naming the cmdlet's Gen 1 complaint.
        def build_read_script
          <<~SCRIPT
            $fogBoot = @(($VM | Get-VMFirmware).BootOrder)
            #{identity_functions}
            #{rows_render}
          SCRIPT
        end

        # Reorder in one script: capture, compute, write once, read back, restore
        # and raise on mismatch. requests is the caller's sequence, already
        # validated by the request: [{Class:, Id: nil-or-string}, ...] in the
        # desired order.
        def build_set_script(requests)
          json = Fog::JSON.encode(requests).gsub("'", "''")
          <<~SCRIPT
            $fogFw = $VM | Get-VMFirmware
            #{identity_functions}
            $fogOrig = @($fogFw.BootOrder)
            $fogReq = ConvertFrom-Json -InputObject '#{json}'
            $fogExp = New-Object System.Collections.Generic.List[object]
            $fogWant = New-Object System.Collections.Generic.List[string]
            $fogTaken = New-Object System.Collections.Generic.List[object]
            foreach ($fogR in @($fogReq)) {
              $fogCls = $fogR.Class
              $fogWanted = "$($fogR.Id)"
              $fogMatch = @($fogOrig | Where-Object {
                (-not $fogTaken.Contains($_)) -and
                ((fog-class $_) -eq $fogCls) -and
                (($fogWanted -eq '') -or ((fog-id $_) -eq $fogWanted))
              })
              if ($fogMatch.Count -eq 0) {
                if ($fogCls -eq 'HardDiskDrive') { $fogDevs = @($VM | Get-VMHardDiskDrive) }
                elseif ($fogCls -eq 'DvdDrive') {
                  if ($fogWanted -ne '') {
                    $fogDevs = @($VM | Get-VMDvdDrive | Where-Object { $_.Id -eq $fogWanted })
                    if ($fogDevs.Count -eq 0) { throw "set_vm_boot_order refuses: DvdDrive $fogWanted is not attached to this VM" }
                  } else {
                    $fogDevs = @($VM | Get-VMDvdDrive)
                  }
                } else { $fogDevs = @($VM | Get-VMNetworkAdapter) }
                if ($fogDevs.Count -eq 0) { throw "set_vm_boot_order refuses: no $fogCls device on this VM to place" }
                foreach ($fogD in $fogDevs) { $fogExp.Add($fogD); $fogWant.Add("$fogCls|$($fogD.Id)") }
              } else {
                foreach ($fogM in $fogMatch) {
                  $fogTaken.Add($fogM)
                  $fogExp.Add($fogM)
                  $fogWant.Add((fog-class $fogM) + '|' + (fog-id $fogM))
                }
              }
            }
            foreach ($fogE in $fogOrig) {
              if (-not $fogTaken.Contains($fogE)) {
                $fogExp.Add($fogE)
                $fogWant.Add((fog-class $fogE) + '|' + (fog-id $fogE))
              }
            }
            $VM | Set-VMFirmware -BootOrder $fogExp.ToArray()
            $fogBoot = @(($VM | Get-VMFirmware).BootOrder)
            $fogGot = @($fogBoot | ForEach-Object { (fog-class $_) + '|' + (fog-id $_) })
            if (($fogGot -join ';') -ne ($fogWant -join ';')) {
              $VM | Set-VMFirmware -BootOrder $fogOrig
              throw ("set_vm_boot_order: the read-back order ($($fogGot -join ';')) is not what was " + \
                     "written ($($fogWant -join ';')); the previous order has been restored")
            }
            #{rows_render}
          SCRIPT
        end
      end
    end
  end
end
