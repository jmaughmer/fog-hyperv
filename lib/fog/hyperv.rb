# frozen_string_literal: true

require 'fog/core'

module Fog
  module Attributes
    autoload :Hypervdatetime, File.expand_path('hyperv/fog_extensions/attributes/datetime.rb', __dir__)
    autoload :Hypervenum, File.expand_path('hyperv/fog_extensions/attributes/enum.rb', __dir__)
    autoload :Hypervenumarray, File.expand_path('hyperv/fog_extensions/attributes/enumarray.rb', __dir__)
    autoload :Hypervtimespan, File.expand_path('hyperv/fog_extensions/attributes/timespan.rb', __dir__)
  end

  module Hyperv
    require 'fog/hyperv/constants'
    require 'fog/hyperv/version'

    extend Fog::Provider

    autoload :Compute, File.expand_path('hyperv/compute', __dir__)

    module Errors
      # A general service error occurred
      class ServiceError < Fog::Errors::Error; end

      # A version constrain was not matched
      class VersionError < ServiceError
        attr_reader :version, :required_version, :function

        def initialize(required_version, version, function)
          @function = function
          @required_version = required_version
          @version = version

          super("#{function} requires at least Hyper-V v#{required_version}, you have v#{version}")
        end
      end

      # A powershell call failed
      class PSError < ServiceError
        attr_reader :stdout, :stderr, :exitcode, :info, :message

        def initialize(output, info)
          @stdout = output.stdout
          @stderr = output.stderr
          @exitcode = output.exitcode
          @info = info
          extract_message

          super(@message)
        end

        # def to_s
        #   ret = [super]
        #   ret << info unless info.nil? || info.empty?
        #   ret.join "\n"
        # end

        private

        # rubocop:disable Naming/MemoizedInstanceVariableName -- Extracting message, not reading it
        def extract_message
          stderr = @stderr.to_s.split("\n").map(&:strip).reject(&:empty?)

          # Find a line ending in an error ID
          @message = stderr.find { |line| line =~ /\(0x[0-9a-f]+\)\.?$/ }
          # Find the last line that isn't include error class information
          @message ||= stderr.take_while { |line| !line.start_with? '+' }.last
          # A cmdlet that finds nothing to act on sets $? to false and exits with
          # 1 without writing anything to the error stream, and that exit code is
          # what gets the call raised here, so this is reached often. A message of
          # nil reads as a broken exception wherever it is reported and hides the
          # one thing the call did report, so say what is known instead.
          stdout = @stdout.to_s.lines.map(&:strip).reject(&:empty?).first(3)
          @message ||= [
            "PowerShell exited with code #{@exitcode} without an error message",
            ("writing to stdout instead: #{stdout.join ' '}" unless stdout.empty?)
          ].compact.join ', '
        end
        # rubocop:enable Naming/MemoizedInstanceVariableName
      end

      # An identifier was handed to a clustered-role lookup that cannot identify a
      # role and would change what the remote cmdlet filters on: nil, empty, or the
      # all-zeros GUID, which PowerShell binds as "no filter" rather than "no match"
      # and would return every role on the cluster. Raised client-side, before any
      # wire traffic.
      class InvalidRoleIdentifier < ServiceError; end

      # A clustered-role read came back shaped in a way the code will not guess
      # about: a successful call with no output, or an error whose
      # FullyQualifiedErrorId carries a prefix that has not been measured against
      # a known cluster state. Both are refused rather than read as "no role",
      # because for the callers of this read "no role" licenses destroying disks.
      class RoleReadUninterpretable < ServiceError; end

      # A path was handed to a destructive request (Remove-Item, or the folder
      # cleanup behind it) that cannot name one exact location: blank, a list of
      # paths, a non-string, or a name carrying * ? [ ] — characters -LiteralPath
      # binds as no file at all while the old -Path render expanded them into a
      # set. Raised client-side, before any wire traffic, because the remote
      # cmdlet cannot be the guard: a -Path render has already widened the scope
      # by the time it runs.
      class InvalidDestructivePath < ServiceError; end

      # The underlying file behind a virtual hard drive was asked to be deleted
      # while its shared-disk state was not exactly proven absent.
      # SupportPersistentReservations reads true on a disk several machines
      # share — deleting the file destroys a disk another running machine is
      # reading — and reads nil when the drive was never read through the
      # property. Both answers are refused; only exactly false licenses the
      # delete, and the refusal precedes every mutation of the drive itself.
      class SharedDiskDeleteRefused < ServiceError; end
    end

    module Associations
      autoload :Collection, File.expand_path('hyperv/fog_extensions/associations/collection', __dir__)
    end

    module Utils
      autoload :ClusterRole, File.expand_path('hyperv/utils/cluster_role', __dir__)
      autoload :DestructivePath, File.expand_path('hyperv/utils/destructive_path', __dir__)
      autoload :Powershell, File.expand_path('hyperv/utils/powershell', __dir__)
      autoload :Winrm, File.expand_path('hyperv/utils/winrm', __dir__)
    end

    autoload :Collection, File.expand_path('hyperv/collection', __dir__)
    autoload :Model, File.expand_path('hyperv/model', __dir__)
    autoload :ModelExtends, File.expand_path('hyperv/model', __dir__)
    autoload :ModelIncludes, File.expand_path('hyperv/model', __dir__)
    autoload :VMCollection, File.expand_path('hyperv/collection', __dir__)

    # Behaviour this fork provides that the published fog-hyperv gem does not, so a
    # caller can ask for it before depending on it. `:tri_state_cluster` means
    # Server#is_clustered answers true, false, or nil (nil when the host runs no
    # cluster service at all) instead of collapsing "unknown" into false.
    # `:exact_host_connection` means the connection cache refuses any host that is
    # neither the configured endpoint nor a name registered for it (the aliases
    # discovery returns), so a machine name carried by request data can never
    # point the client — and its credentials — at a host nobody configured.
    # `:literal_path_destructive` means a destructive path request binds
    # -LiteralPath instead of -Path and refuses, before any wire traffic, a path
    # that cannot name one exact location, so a machine name carrying wildcard
    # characters can no longer expand into a deletion set that includes its
    # siblings.
    # `:stdout_json_hygiene` means every rendered cmdlet call routes its
    # warning, verbose, debug and information records to the host's error
    # channel instead of stdout, so a cmdlet that advises — the cluster
    # cmdlets' remote-execution warning was measured landing before the payload
    # — can no longer write itself into the stdout this gem parses as JSON: a
    # successful call decodes instead of raising a DecodeError over a
    # Warning: line.
    # A caller on an older gem sees no constant here and must treat every fork
    # behaviour as absent.
    CAPABILITIES = %i[tri_state_cluster exact_host_connection literal_path_destructive stdout_json_hygiene].freeze

    service(:compute, 'Compute')

    # Convert a piece of data from being snake_case to being CamelCase
    def self.camelize(data)
      case data
      when Array
        data.collect { |d| camelize(d) }
      when Hash
        data.each_with_object({}) do |(k, v), hash|
          value = v
          value = camelize(v) if v.is_a?(Hash) || (v.is_a?(Array) && v.all?(Hash))
          hash[camelize(k)] = value
        end
      when Symbol
        camelize(data.to_s).to_sym
      when String
        data.split('_').collect(&:capitalize).join
      else
        data
      end
    end

    # Convert a piece of data from being CamelCase to being snake_case
    def self.uncamelize(data)
      case data
      when Array
        data.collect { |d| uncamelize(d) }
      when Hash
        data.each_with_object({}) do |(k, v), hash|
          value = v
          value = uncamelize(v) if v.is_a?(Hash) || (v.is_a?(Array) && v.all?(Hash))
          hash[uncamelize(k)] = value
        end
      when Symbol
        uncamelize(data.to_s).to_sym
      when String
        data.to_s
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .tr('-', '_')
            .downcase.to_sym
      else
        data
      end
    end
  end
end
