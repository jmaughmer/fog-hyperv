# frozen_string_literal: true

module Fog::Hyperv
  class Compute < Fog::Service
    requires :hyperv_username
    recognizes :hyperv_endpoint, :hyperv_host,
               :hyperv_password,
               :hyperv_transport, :hyperv_realm,
               :hyperv_ssl_verify, :hyperv_ca_trust_path,
               :hyperv_client_cert, :hyperv_client_key, :hyperv_key_pass,
               :hyperv_debug

    secrets :hyperv_password, :hyperv_key_pass, :connection

    model_path 'fog/hyperv/compute/models'
    model :bios
    model :cluster
    collection :clusters
    model :cluster_network
    collection :cluster_networks
    model :cluster_node
    collection :cluster_nodes
    model :cluster_shared_volume
    collection :cluster_shared_volumes
    model :cluster_virtual_machine_role
    collection :cluster_virtual_machine_roles
    model :com_port
    collection :com_ports
    model :dvd_drive
    collection :dvd_drives
    model :firmware
    model :floppy_drive
    collection :floppy_drives
    model :hard_drive
    collection :hard_drives
    model :host
    collection :hosts
    model :integration_service
    collection :integration_services
    model :network_adapter
    model :network_adapter_vlan
    collection :network_adapters
    model :security
    model :server
    collection :servers
    model :switch
    collection :switches
    model :vhd
    collection :vhds

    request_path 'fog/hyperv/compute/requests'
    request :add_cluster_virtual_machine_role
    request :add_vm_dvd_drive
    request :add_vm_hard_disk_drive
    request :add_vm_network_adapter
    request :connect_vm_network_adapter
    request :disable_vm_integration_service
    request :disable_vm_tpm
    request :disconnect_vm_network_adapter
    request :enable_vm_integration_service
    request :enable_vm_tpm
    request :get_cluster
    request :get_cluster_available_disk
    request :get_cluster_network
    request :get_cluster_node
    request :get_cluster_quorum
    request :get_cluster_shared_volume
    request :get_cluster_virtual_machine_role
    request :get_vhd
    request :get_vm
    request :get_vm_bios
    request :get_vm_com_port
    request :get_vm_dvd_drive
    request :get_vm_firmware
    request :get_vm_floppy_disk_drive
    request :get_vm_group
    request :get_vm_hard_disk_drive
    request :get_vm_host
    request :get_vm_host_cluster
    request :get_vm_host_sbt
    request :get_vm_integration_service
    request :get_vm_key_protector
    request :get_vm_network_adapter
    request :get_vm_network_adapter_vlan
    request :get_vm_security
    request :get_vm_switch
    request :new_vhd
    request :new_vm
    request :new_vm_switch
    request :optimize_vhd
    request :remove_cluster_virtual_machine_role
    request :remove_item
    request :remove_vm
    request :remove_vm_dvd_drive
    request :remove_vm_hard_disk_drive
    request :remove_vm_network_adapter
    request :remove_vm_switch
    request :rename_vm
    request :rename_vm_network_adapter
    request :rename_vm_switch
    request :resize_vhd
    request :restart_vm
    request :resume_vm
    request :save_vm
    request :set_vm
    request :set_vm_bios
    request :set_vm_com_port
    request :set_vm_dvd_drive
    request :set_vm_firmware
    request :set_vm_floppy_disk_drive
    request :set_vm_hard_disk_drive
    request :set_vm_key_protector
    request :set_vm_network_adapter
    request :set_vm_network_adapter_vlan
    request :set_vm_security
    request :set_vm_switch
    request :start_vm
    request :stop_vm
    request :suspend_vm

    class Shared
      def version
        '0.0'
      end

      protected

      def requires(opts, *args)
        missing = args - opts.keys
        return if missing.none?

        method = caller[0][/`.*'/][1..-2]
        raise(ArgumentError, "#{missing.first} is required for #{method}") if missing.length == 1
        raise(ArgumentError, "#{missing[0...-1].join(', ')}, and #{missing[-1]} are required for #{method}") if missing.any?
      end

      def requires_one(opts, *args)
        missing = args - opts.keys
        return if missing.length < args.length

        method = caller[0][/`.*'/][1..-2]
        raise(ArgumentError, "#{missing[0...-1].join(', ')}, or #{missing[-1]} is required for #{method}")
      end

      def requires_version(required_version)
        method = caller[0][/`.*'/][1..-2].split('_')
        method = "#{method[0].capitalize}-#{Fog::Hyperv.camelize(method[1..].join('_'))}"

        raise Fog::Hyperv::Errors::VersionError.new(required_version, version, method) \
          unless Gem::Version.new(version) >= Gem::Version.new(required_version)
      end
    end

    class Real < Shared
      include Fog::Hyperv::Utils::Winrm

      attr_reader :logger

      attr_accessor :bake_optmap, :bake_json

      def initialize(options = {}) # rubocop:disable Style/OptionHash, Lint/MissingSuper -- No super method
        require 'fog/json'
        require 'logging'

        # Transfer cmdlet parameters as JSON object
        @bake_json = true
        @bake_optmap = true

        @connections = {}
        @hyperv_endpoint = options[:hyperv_endpoint]
        @hyperv_endpoint ||= "http://#{options[:hyperv_host]}:5985/wsman" if options[:hyperv_host]
        @hyperv_username = options[:hyperv_username]
        @hyperv_password = options[:hyperv_password]
        @hyperv_realm = options[:hyperv_realm]
        @hyperv_ca_trust_path = options[:hyperv_ca_trust_path]
        @hyperv_client_cert = options[:hyperv_client_cert]
        @hyperv_client_key = options[:hyperv_client_key]
        @hyperv_key_pass = options[:hyperv_key_pass]

        # Verifying the peer's certificate on an https endpoint is the default: the
        # blanket no_ssl_peer_verification this used to hardcode was set when the
        # alternative failed every self-signed listener outright, and over a routed
        # path an unverified listener is only as trustworthy as the nearest router.
        # hyperv_ssl_verify: false is the deliberate opt-out.
        @hyperv_ssl_verify = case options.fetch(:hyperv_ssl_verify) { true }
                             when false, /\A(false|f|no|0)\z/i then false
                             else true
                             end

        # What :negotiate actually speaks is NTLM — ruby-winrm wraps NTLM tokens in
        # the Negotiate scheme and never attempts a Kerberos leg — and NTLM is
        # deprecated by its vendor, with disabling it by default the stated end
        # state. A realm answers the same need over Kerberos, and a client
        # certificate over the transport that authenticates by certificate; both
        # become the default transport when named and nothing else is.
        transport = options[:hyperv_transport]
        if transport.is_a?(String)
          transport = transport.strip.downcase.to_sym
          transport = nil if transport.to_s.empty?
        end
        @hyperv_transport = transport || (@hyperv_realm ? :kerberos : (@hyperv_client_cert ? :ssl : :negotiate))

        # Hide NEGOTIATE logging from WinRM to reduce log spam when debugging
        Logging.logger['WinRM::HTTP::HttpNegotiate'].level = :error

        @logger = Logging.logger[Fog::Hyperv]
        if options[:hyperv_debug]
          logger.level = :debug
          logger.add_appenders Logging.appenders.stdout
        end

        connect
      end

      # Is the provider communicating with a Hyper-V install on the local machine
      def local?
        false # @hyperv_endpoint.nil?
      end

      # Is the Hyper-V provider valid - i.e. can it communicate with a Hyper-V install
      # @return [Boolean] is the endpoint running a working Hyper-V setup
      def valid?
        if local?
          run_cmd('Get-VMHost', _return_fields: :name) && true
        else
          # run_wql already returns the first instance, not the xml_fragment list
          run_wql('SELECT Name FROM Msvm_ComputerSystem WHERE Caption = "Hosting Computer System"')[:name] && true
        end
      rescue StandardError => e
        logger.debug "Validation failed with #{e.class}; #{e.message}"
        false
      end

      # Does the Hyper-V install support clusters - i.e. is the machine joined to a failover cluster
      # @return [Boolean] is the Hyper-V setup possible to cluster
      def supports_clusters?
        # run_wql already returns the first instance, and appends /* itself
        run_wql('SELECT Name FROM MSCluster_ResourceGroup', _namespace: 'root/mscluster')[:name] && true
      rescue StandardError => e
        logger.debug "Cluster support checking failed with #{e.class}: #{e.message}"
        false
      end
    end

    # Mocked version of the provider for use in testing
    class Mock < Shared
      def initialize(_options = {}) # rubocop:disable Lint/MissingSuper -- No super method
        require 'fog/json'
      end

      # The two capability questions live on Real because they ask a machine: #valid?
      # reads Msvm_ComputerSystem over WMI and #supports_clusters? asks
      # root/mscluster. A mocked client has no machine to ask, so it answered neither —
      # not false, but no method at all — and a consumer that gates on
      # respond_to?(:supports_clusters?) sent every mocked cluster down its
      # stand-alone path. The cluster models were then testable while the code that
      # decides whether to use them was not. Under a mock the honest equivalent of a
      # probe is the fixture the request would have been served from, so that is what
      # these read.
      #
      # @return [Boolean] would this host answer a management call
      def valid?
        !handle_mock_response(_method: 'get_vm_host').empty?
      rescue StandardError
        false
      end

      # True for every mocked client, because the mock dataset describes a clustered
      # host. A consumer that needs the stand-alone answer can not get it from these
      # fixtures; it has to say so itself.
      #
      # @return [Boolean] is this host joined to a failover cluster
      def supports_clusters?
        !handle_mock_response(_method: 'get_cluster').empty?
      rescue StandardError
        false
      end

      def method_missing(method, *args)
        if requests.find { |_, k| k == method }
          # handle_mock_response takes keyword arguments, and a request's arguments
          # arrive here as a positional Hash, so they have to be splatted: passed
          # through as-is, every request that has no Mock of its own raised
          # "wrong number of arguments (given 1, expected 0)" instead of answering
          # from its mock file.
          handle_mock_response(**(args.first || {}), _method: method)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        requests.find { |_, k| k == method } || super
      end

      def self.method_defined?(method)
        Fog::Hyperv::Compute.requests.find { |_, k| k == method } || super
      end

      private

      def handle_mock_response(_method: nil, **args)
        if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('4.0')
          _method ||= caller[0][/'.*'/][1..-2].split('#').last
          _method ||= caller[1][/'.*'/][1..-2].split('#').last
        else
          _method ||= caller[0][/`.*'/][1..-2]
          _method ||= caller[1][/`.*'/][1..-2]
        end

        path = File.join File.dirname(__FILE__), 'compute', 'requests', 'mock_files', "#{_method}.json"
        raise Fog::Errors::MockNotImplemented, "No mocked data for #{path}" unless File.exist? path
        raise Fog::Errors::MockNotImplemented, 'Not implementing skipping of json' if args[:_skip_json]
        raise Fog::Errors::MockNotImplemented, 'Not implementing skipping of uncamelize' if args[:_skip_uncamelize]

        ret = Fog::JSON.decode(File.read(path))
        ret = Fog::Hyperv.uncamelize(ret)

        if args[:_return_fields]
          ret = ret.map do |obj|
            obj.slice(*args[:_return_fields])
          end
        end
        ret
      end
    end
  end
end
