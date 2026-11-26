# frozen_string_literal: true

require 'fog/compute/models/server'

class Fog::Hyperv::Compute
  # rubocop:disable Metrics/ClassLength

  # A Hyper-V VM
  class Server < Fog::Compute::Server
    extend Fog::Hyperv::ModelExtends
    include Fog::Hyperv::ModelIncludes

    # The path shapes Windows treats as naming one exact location: a drive
    # letter with a root, or a UNC share. Anything else is resolved by
    # whatever consumes it — and the WinRM shell consumes a relative path
    # against its own working directory, measured C:\ on this fork.
    ABSOLUTE_PATH = %r{\A(?:\w:[\\/]|[\\/]{2}\w+[\\/])}i

    # rubocop:disable Layout/HashAlignment

    # VM runtime state
    #
    # @note Defined by Microsoft.HyperV.PowerShell.VMState
    VM_STATE_ENUM_VALUES = {
      Other:              1,
      Running:            2,
      Off:                3,
      Stopping:           4,
      Saved:              6,
      Paused:             9,
      Starting:           10,
      Reset:              11,
      Saving:             32_773,
      Pausing:            32_776,
      Resuming:           32_777,
      FastSaved:          32_779,
      FastSaving:         32_780,
      ForceShutdown:      32_781,
      ForceReboot:        32_782,
      Hibernated:         32_783,
      ComponentServicing: 32_784,
      RunningCritical:    32_785,
      OffCritical:        32_786,
      StoppingCritical:   32_787,
      SavedCritical:      32_788,
      PausedCritical:     32_789,
      StartingCritical:   32_790,
      ResetCritical:      32_791,
      SavingCritical:     32_792,
      PausingCritical:    32_793,
      ResumingCritical:   32_794,
      FastSavedCritical:  32_795,
      FastSavingCritical: 32_796
    }.freeze

    # VM object status
    #
    # @note Defined by Microsoft.HyperV.PowerShell.VMOperationalStatus
    VM_STATUS_ENUM_VALUES = {
      Ok:                        2,
      Degraded:                  3,
      PredictiveFailure:         5,
      InService:                 11,
      Dormant:                   15,
      SupportingEntityInError:   16,
      CreatingSnapshot:          32_768,
      ApplyingSnapshot:          23_769,
      DeletingSnapshot:          32_770,
      WaitingToStart:            32_771,
      MergingDisks:              32_772,
      ExportingVirtualMachine:   32_773,
      MigratingVirtualMachine:   32_774,
      BackingUpVirtualMachine:   32_776,
      ModifyingUpVirtualMachine: 32_777,
      StorageMigrationPhaseOne:  32_778,
      StorageMigrationPhaseTwo:  32_779,
      MigratingPlannedVm:        32_780,
      CheckingCompatibility:     32_781,
      ApplicationCriticalState:  32_782,
      CommunicationTimedOut:     32_783,
      CommunicationFailed:       32_784,
      NoIommu:                   32_785,
      NoIovSupportInNic:         32_786,
      SwitchNotInIovMode:        32_787,
      IovBlockedByPolicy:        32_788,
      IovNoAvailResources:       32_789,
      IovGuestDriversNeeded:     32_790,
      CriticalIoError:           32_795
    }.freeze

    # VM firmware generation - i.e. BIOS/UEFI
    VM_GENERATION_VALUES = {
      BIOS: 1,
      UEFI: 2
    }.freeze
    # rubocop:enable Layout/HashAlignment

    # @!attribute [r] id
    #   @return [String] the GUID of the VM
    identity :id
    alias vm_id :id

    # @!attribute [r] computer_name
    #   @return [String] the name of the host running the VM
    attribute :computer_name

    # @!attribute name
    #   @return [String] the name of the VM
    attribute :name
    alias vm_name :name
    # @!attribute [r] creation_time
    #   @return [Time] the time the VM was created
    attribute :creation_time, type: :hypervdatetime
    # @!attribute dynamic_memory_enabled
    #   @return [Boolean] if memory is dynamically handled - sliding between #memory_minimum and #memory_maximum
    attribute :dynamic_memory_enabled, type: :boolean, default: false
    # @!attribute [r] generation
    #   @return [Symbol] the VM firmware generation
    attribute :generation, type: :hypervenum, values: VM_GENERATION_VALUES, default: :UEFI
    # @!attribute [r] is_clustered
    #   @return [Boolean,nil] true when the cluster confirms this machine runs as a
    #     role, false when the cluster positively answered that it has none, and nil
    #     when nothing was established — no id, or an endpoint that is not a cluster
    #     and so could not be asked. There is no default: an unchecked machine has to
    #     read as unknown, because false is the answer that licenses disk removal.
    attribute :is_clustered, type: :boolean
    # @!attribute [r] state
    #   @return [Symbol] the state of the VM
    #   @see VM_STATE_ENUM_VALUES
    attribute :state, type: :hypervenum, values: VM_STATE_ENUM_VALUES
    # @!attribute [r] primary_operational_status
    #   @return [Symbol] the primary status of the VM
    #   @see VM_STATUS_ENUM_VALUES
    attribute :primary_operational_status, type: :hypervenum, values: VM_STATUS_ENUM_VALUES
    # @!attribute [r] secondary_operational_status
    #   @return [Symbol] the secondary status of the VM
    #   @see VM_STATUS_ENUM_VALUES
    attribute :secondary_operational_status, type: :hypervenum, values: VM_STATUS_ENUM_VALUES
    # @!attribute [r] memory_assigned
    #   @return [Integer] the memory assigned to the VM on startup
    attribute :memory_assigned, type: :integer
    # @!attribute memory_maximum
    #   @return [Integer] the maximum amount of memory the VM can assign when #dynamic_memory_enabled
    attribute :memory_maximum, type: :integer, default: 17_179_869_184
    # @!attribute memory_minimum
    #   @return [Integer] the minimum amount of memory the VM can assign when #dynamic_memory_enabled
    attribute :memory_minimum, type: :integer, default: 536_870_912
    # @!attribute memory_startup
    #   @return [Integer] the starting amount of memory the VM will be assigned
    attribute :memory_startup, type: :integer, default: 536_870_912
    # @!attribute notes
    #   @return [String] user-specified notes for the VM
    attribute :notes, type: :string
    # @!attribute path
    #   @return [String] the path on disk where the VM configuration is stored
    attribute :path, type: :string
    # @!attribute placement_path
    #   @return [String] the absolute folder this machine's disks are built
    #     in — the placement decision's answer, such as a cluster shared
    #     volume's mount folder. When set it replaces the host's own disk
    #     root outright (the host is not even asked); a relative value is
    #     refused at use, not joined.
    attribute :placement_path, type: :string
    # @!attribute processor_count
    #   @return [Integer] the number of processors in the VM
    attribute :processor_count, type: :integer, default: 1
    # @!attribute [r] uptime
    #   @return [Time] the amount of time the VM has been online
    attribute :uptime, type: :hypervtimespan

    # @!attribute com_ports
    #   @return [Array<ComPort>] the COM ports on the VM
    collection :com_ports
    # @!attribute dvd_drives
    #   @return [Array<DvdDrive>] the DVD drives on the VM
    collection :dvd_drives
    # @!attribute floppy_drives
    #   @note only supported on #generation +:BIOS+
    #   @return [Array<FloppyDrive>] the floppy drives on the VM
    collection :floppy_drives
    # @!attribute hard_drives
    #   @return [Array<HardDrive>] the hard drives on the VM
    collection :hard_drives
    # @!attribute integration_services
    #   @return [Array<IntegrationService>] the integration services on the VM
    collection :integration_services
    # @!attribute network_adapters
    #   @return [Array<NetworkAdapter>] the network adapters on the VM
    collection :network_adapters
    # @!attribute vhds
    #   @return [Array<Vhd>] the VHD images in use by the VM
    collection :vhds

    has_one :bios, :bios
    has_one :security, :security

    def initialize(attrs = {})
      @cluster = attrs.delete :cluster
      @computer = attrs.delete :computer

      super
    end

    # @!attribute [r] bios
    # @return [Bios,Firmware] BIOS/UEFI configuration depending on generation
    def bios
      associations[:bios] ||= begin
        requires :generation, :id
        if generation == :BIOS
          klass = Fog::Hyperv::Compute::Bios
          method = :get_vm_bios
        else
          klass = Fog::Hyperv::Compute::Firmware
          method = :get_vm_firmware
        end

        klass.new(
          **service.public_send(
            method,
            computer_name: computer_name,
            vm_id: vm_id,

            _return_fields: klass.attributes
          ),

          vm: self,
          service: @service,
          computer: @computer,
          cluster: @cluster
        )
      end
    end
    alias firmware :bios

    # @!attribute [r] security
    # @return [Security] UEFI security configuration, if #generation is +:UEFI+
    def security
      return unless persisted?

      requires :generation
      return unless generation == :UEFI

      security = service.get_vm_security(
        computer_name: computer_name,
        vm_id: vm_id,

        _return_fields: Fog::Hyperv::Compute::Security.attributes
      )
      return unless security.is_a? Hash

      associations[:security] ||= Fog::Hyperv::Compute::Security.new(
        **security,

        vm: self,
        service: @service,
        computer: @computer,
        cluster: @cluster
      )
    end

    # @!attribute tpm_enabled
    # @return [Boolean] if a vTPM is enabled on the VM, only available if #generation is +:UEFI+
    def tpm_enabled
      security&.tpm_enabled
    end

    def tpm_enabled=(enabled)
      return unless security
      return if enabled == tpm_enabled

      security.tpm_enabled = enabled
      security.save
      enabled # rubocop:disable Lint/Void -- Needs to shadow the result of security.save
    end

    # Start the VM
    def start
      requires :id

      service.start_vm(computer_name: computer_name, id: id)
      true
    end

    # Stop the VM
    # @param [Boolean] turn_off perform an instant power off instead of an ACPI shutdown
    def stop(turn_off: false)
      requires :id

      service.stop_vm(computer_name: computer_name, id: id, turn_off: turn_off)
      true
    end

    # Suspend VM execution
    def suspend
      requires :id

      service.suspend_vm(computer_name: computer_name, id: id)
      true
    end

    # Resume suspended VM execution
    def resume
      requires :id

      service.resume_vm(computer_name: computer_name, id: id)
      true
    end

    # Hibernate the VM, i.e. save VM state to disk and turn it off
    def hibernate
      requires :id

      service.save_vm(computer_name: computer_name, id: id)
      true
    end

    # Restart the VM
    # @note This method will always cause a hard reset, i.e. power off and on without waiting for OS shutdown
    def restart
      requires :id

      service.restart_vm(computer_name: computer_name, id: id)
      true
    end
    alias reboot :restart

    # Update the VM object to the latest version
    def update_version
      requires :id

      service.update_vm(computer_name: computer_name, id: id)
      true
    end

    # Remove the VM object from Hyper-V
    # @param [Boolean] underlying remove the underlying configuration directory from disk on the Hyper-V host
    #
    # @note if the VM has VHDs, make sure to remove them first to not leave the VM data remaining on disk
    # @note underlying will remove the +full+ path of the VM, make sure this is what you want before using it
    def destroy(underlying = nil)
      underlying = true if underlying.nil? && attributes[:path]&.end_with?(attributes[:name])

      requires :id
      requires :path if underlying
      stop turn_off: true if ready?

      service.remove_vm(computer_name: computer_name, id: id)
      service.remove_item(path: path, computer_name: computer_name, recurse: true) if underlying
      true
    end

    # Create the VM object if it doesn't exist
    # @param [Symbol] boot_device the default boot device to configure the VM with, one of BOOT_DEVICE
    # @param [String] switch_name the name of a Switch to connect the VM to on creation
    # @option attrs [String] :path
    #   a custom path to store the VM configuration under - will use a subdir under the default config path if relative
    def create(boot_device: nil, switch_name: nil, **attrs)
      attrs[:no_vhd] = true unless attrs[:new_vhd_path]
      attrs[:path] = join_config_root(attrs[:path]) if attrs[:path]

      # Attributes that can't be set as part of the New-VM call
      post_create_attributes = {
        processor_count: processor_count > 1 ? processor_count : nil,
        notes: notes.nil? || notes == '' ? nil : notes
      }
      if dynamic_memory_enabled
        post_create_attributes.merge!(
          dynamic_memory_enabled: true,
          memory_minimum_bytes: memory_minimum,
          memory_maximum_bytes: memory_maximum
        )
      end
      post_create_attributes.compact!

      merge_attributes(
        service.new_vm(
          computer_name: computer_name,
          name: name,

          generation: generation_num,
          memory_startup_bytes: memory_startup,
          boot_device: boot_device,
          switch_name: switch_name,

          **attrs,

          _return_fields: self.class.attributes
        )
      )
      attributes.merge! post_create_attributes if post_create_attributes.any?
      save if dirty?

      # Save any associations that have been manually assigned before VM creation
      self.class.associations.each_key do |assoc|
        next unless associations.key? assoc

        associations[assoc].select do |obj|
          obj.computer_name = computer_name if obj.respond_to?(:computer_name=)
          obj.vm_id = id if obj.respond_to?(:vm_id=)

          obj.save if obj.dirty? || !obj.persisted?
          next if assoc != :vhd || hard_drives.none? { |hdd| hdd.path == vhd.path }

          hard_drives.create(path: vhd.path)
        end
        associations[assoc].clear
      end

      self
    end

    def update
      requires :id

      changes = {
        processor_count: changed!(:processor_count),
        memory_startup_bytes: changed!(:memory_startup),
        new_vm_name: changed!(:name)
      }.compact
      if dynamic_memory_enabled
        changes[:dynamic_memory] = true if changed?(:dynamic_memory_enabled)
        changes[:memory_minimum_bytes] = memory_minimum if changed?(:dynamic_memory_enabled, :memory_minimum)
        changes[:memory_maximum_bytes] = memory_maximum if changed?(:dynamic_memory_enabled, :memory_maximum)
      elsif changed?(:dynamic_memory_enabled)
        changes[:static_memory] = true
      end
      changes.compact!

      changes[:notes] = notes || '' if changed? :notes
      return self unless changes.any?

      merge_attributes(
        service.set_vm(
          computer_name: old.computer_name,
          id: old.id,

          **changes,

          _always_include: changes.keys,
          _return_fields: self.class.attributes
        )
      )
    end

    # @!attribute [r] cluster_role
    #   @return [ClusterVirtualMachineRole,nil] the clustered role this machine runs
    #     as, or nil when it has none — which covers a machine on clustered hardware
    #     that was never made highly available, and a machine on a stand-alone host,
    #     where there is no cluster to ask. Memoised, including the nil, because every
    #     later call is free once one has been made; #reload drops the memo so a model
    #     that survives a failover re-asks rather than repeats.
    #
    #   The lookup is by the machine's GUID, the way the plugin holds it: the role
    #     group's real name is the machine's name as the cluster knows it, which is
    #     not a name this side can construct (it has no local name source, and a
    #     rename silently changes it). An unclassifiable read error is deliberately
    #     not rescued here — "could not tell" must stay an error rather than read as
    #     "no role", because "no role" is the answer that licenses disk removal.
    def cluster_role
      return @cluster_role if instance_variable_defined?(:@cluster_role)

      unless cluster_queriable?
        # Nothing to ask about, or an endpoint that cannot answer cluster
        # questions at all — asking would raise before it ever reached a role.
        return @cluster_role = nil
      end

      @cluster_role = begin
        service.cluster_virtual_machine_roles.get(vm_id: id)
      rescue Fog::Errors::NotFound
        # The one miss answer that is safe to read as "no role": the read
        # request only lets NotFound through for identifiers the cluster
        # positively answered, and it re-raises everything else.
        nil
      end
    end

    # @!attribute [r] clustered?
    #   @return [Boolean] whether this machine fails over with the cluster
    def clustered?
      !cluster_role.nil?
    end

    # @!attribute [r] is_clustered
    #   @return [Boolean,nil] the tri-state of the cluster question: true when the
    #     cluster confirmed a role for this machine, false when the cluster answered
    #     that it has none, and nil when the question was never answered — a machine
    #     with no id to ask about, or an endpoint that is not a cluster endpoint and
    #     so cannot answer it. An error is never flattened into nil or false either:
    #     it propagates.
    #
    #   Not knowing and being told no are kept apart on purpose. The false is only
    #     ever reached through a read that classified the cluster's answer, because
    #     downstream disk removal is gated on that answer, and a probe that merely
    #     failed to find a cluster does not distinguish a stand-alone host from a
    #     clustered node whose cluster service is down. Get-VM's own IsClustered
    #     property is deliberately not used as the source of this value: it is the
    #     payload of the node the machine was read from, and this method exists to
    #     say something the payload cannot. #attributes still carries it for callers
    #     that want it.
    #
    #   Memoises every answer including the negative, and checks the memo
    #   before anything else (Real#supports_clusters? is a live
    #   root/mscluster round trip, and for a model the guard could ask
    #   about, running it before the memo check billed it to every call —
    #   the count this PR changes). A first call still pays the probes the
    #   question needs: one when a role read has already populated
    #   #cluster_role's memo, two when this call is what warms it —
    #   #cluster_role's own askable-guard dials on its cold read, exactly
    #   as base paid. Every later call on a model that HOLDS an answer is
    #   free; a model that was never answered keeps probing per call on an
    #   endpoint that cannot answer it, as it always did (the no-id model
    #   short-circuits before any probe, also as it always did). An answer
    #   therefore outlives a gate that flips after it
    #   was given — the endpoint gave it while it could. #reload is what
    #   re-asks: it drops this memo and #cluster_role's. Fog's own
    #   persistence methods read #attributes, so the memo never leaks into
    #   anything saved.
    #
    #   The name matches the IsClustered property of every payload this model reads,
    #   which is why it stays non-predicate despite returning the tri-state: it is a
    #   published attribute name, not a local boolean choice.
    def is_clustered # rubocop:disable Naming/PredicatePrefix
      return @is_clustered if instance_variable_defined?(:@is_clustered)
      return nil unless cluster_queriable?

      @is_clustered = !cluster_role.nil?
    end

    # Whether the cluster question can be asked at all: it needs a machine id to ask
    # about and a service that speaks clusters. A machine with neither has not been
    # asked, which is the nil of the tri-state rather than an answer.
    # @return [Boolean]
    def cluster_queriable?
      !id.nil? && !(service.respond_to?(:supports_clusters?) && !service.supports_clusters?)
    end

    # @!attribute [r] owner_node
    #   @return [String] the node running this machine now. computer_name is the node
    #     the machine was read from, and that goes stale the moment a role moves: the
    #     machine is still the same GUID, it is just somewhere else. Anything that
    #     acts on the machine by pointing at a node — every run_cmd in this gem does,
    #     reload included — wants this rather than computer_name once a cluster is in
    #     play.
    def owner_node
      cluster_role&.owner_node || computer_name
    end

    # Reload the VM attributes from the Hyper-V server.
    #
    # A reload also drops the cluster memos (#cluster_role and
    # #is_clustered): they are the machine's answers, not the payload's, and
    # a model held across a failover must re-ask them rather than repeat
    # them — the staleness #owner_node documents is exactly what a memo that
    # survived reload would reintroduce. They are dropped BEFORE the read,
    # so even a reload that finds nothing does not leave a stale cluster
    # answer standing: the next cluster question goes to the endpoint again.
    # #cluster — the association the collection handed the model when it
    # built it — is not one of these answers and survives by design: a
    # failover moves a role, not the cluster.
    # @return [self] if model successfully reloaded
    # @return [nil] only when the read SUCCEEDED and answered with nothing
    #   for this machine — an empty successful stdout is the read's one nil
    #   (run_cmdlist returns it before any decode). A read that goes wrong
    #   does not answer nil, it raises: a missing :id raises the
    #   ArgumentError fog-core's requires throws before a wire is dialled;
    #   a failed cmdlet raises Fog::Hyperv::Errors::PSError (run_cmdlist
    #   checks exitcode after every run, and $? whenever stderr carries a
    #   FullyQualifiedErrorId); and a transport that cannot carry the run
    #   at all raises its own error — the Errno:: family or winrm-gem
    #   errors, not PSError. reload carries no rescue, so whichever it is
    #   propagates untouched. The second @return line used to promise nil
    #   for "something went wrong"; no went-wrong path ever answered nil
    #   (FOG-33, the NIT-1 of the FOG-28 review).
    def reload
      requires :id

      %i[@cluster_role @is_clustered].each do |ivar|
        remove_instance_variable(ivar) if instance_variable_defined?(ivar)
      end

      data = service.get_vm computer_name: computer_name, id: id, _return_fields: self.class.attributes
      return unless data

      merge_attributes(data)
      @old = data

      self
    end

    # Build a path for where to store a VHD of a given name
    # @return [String] the absolute path for the VHD
    # @raise [Fog::Hyperv::Errors::InvalidPlacementPath] when neither a
    #   placement folder nor the host's disk root can compose an absolute
    #   path — a relative one would be resolved against the remote shell's
    #   working directory, not the machine's storage.
    def build_vhd_path(filename = nil)
      requires :name

      folder = placement_folder
      path =
        if folder
          [folder, filename].compact.join('\\')
        else
          disk_root = computer&.virtual_hard_disk_path
          if disk_root.nil? || disk_root.strip.empty?
            raise Fog::Hyperv::Errors::InvalidPlacementPath,
                  "Refusing to build a disk path for '#{name}': no placement folder was given and " \
                  "the hosting computer #{computer_name.inspect} answers no disk root to build under. " \
                  'The join would come out relative and the remote shell would resolve it against ' \
                  'its own working directory, not the machine.'
          end
          [disk_root, name, filename].compact.join('\\')
        end
      unless path =~ ABSOLUTE_PATH
        raise Fog::Hyperv::Errors::InvalidPlacementPath,
              "Refusing the relative disk path #{path.inspect} built for '#{name}': a relative path " \
              'is resolved against the remote shell\'s working directory, not the machine\'s storage.'
      end
      path
    end

    # Build a path for where to store configuration files
    # @return [String] the absolute path for the configuration store
    # @raise [Fog::Hyperv::Errors::InvalidPlacementPath] when the host
    #   answers no configuration root — same rule as #build_vhd_path.
    def build_config_path(subdir = nil)
      requires :name

      config_root = computer&.virtual_machine_path
      if config_root.nil? || config_root.strip.empty?
        raise Fog::Hyperv::Errors::InvalidPlacementPath,
              "Refusing to build a config path for '#{name}': the hosting computer " \
              "#{computer_name.inspect} answers no config root to build under."
      end
      [config_root, name, subdir].compact.join('\\')
    end

    # The machine's named placement folder, if the caller named one.
    # @return [String, nil] the placement folder when one was set
    # @raise [Fog::Hyperv::Errors::InvalidPlacementPath] when the folder
    #   given is not absolute.
    def placement_folder
      return nil if placement_path.nil? || placement_path.to_s.strip.empty?
      unless placement_path =~ ABSOLUTE_PATH
        raise Fog::Hyperv::Errors::InvalidPlacementPath,
              "Refusing to place '#{name}' in the relative folder #{placement_path.inspect}: a " \
              'placement folder must be absolute (a drive root or a UNC share); a relative one is ' \
              'resolved against the remote shell\'s working directory, not the machine\'s storage.'
      end
      placement_path
    end

    # Compose a caller-given configuration path onto the host's config root,
    # absolutely. An absolute path is already one exact location and rides
    # through untouched, without asking the host anything.
    # @return [String] the absolute path
    # @raise [Fog::Hyperv::Errors::InvalidPlacementPath] when the path is
    #   relative and the host answers no config root.
    def join_config_root(path)
      return path if path =~ ABSOLUTE_PATH

      config_root = computer&.virtual_machine_path
      if config_root.nil? || config_root.strip.empty?
        raise Fog::Hyperv::Errors::InvalidPlacementPath,
              "Refusing to resolve the relative config path #{path.inspect}: the hosting computer " \
              "#{computer_name.inspect} answers no config root to resolve it against."
      end
      [config_root, path].join('\\')
    end

    # Get the username of the main system account
    # @return [String] the system account username - usually "Administrator" or "root"
    def username
      @username || 'Administrator'
    end

    # @return [Boolean] if the VM is ready? (i.e. #state is +:Running+)
    def ready?
      state_num == 2
    end

    # @return [Array<String>] the MAC addresses of all attached network adapters
    def mac_addresses
      network_adapters.map(&:mac_address)
    end

    # @return [Array<String>] the IP addresses of all attached network adapters
    def ip_addresses
      network_adapters.map(&:ip_addresses).flatten
    end

    # @return [Array<String>] the public (not link-local) IP addresses of all attached network adapters
    def public_ip_addresses
      ip_addresses
        .map { |a| IPAddr.new a }
        .reject(&:link_local?)
        .map(&:to_s)
    end

    # @return [String,nil] the first public IP address of the VM - if any
    def public_ip_address
      public_ip_addresses.first
    end
  end
  # rubocop:enable Metrics/ClassLength
end
