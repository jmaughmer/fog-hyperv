# frozen_string_literal: true

# rubocop:disable Metrics/ModuleLength

# WinRM helper methods
module Fog::Hyperv::Utils::Winrm
  # Struct emulating a WinRM shell return
  LocalExecOutput = Struct.new(:stdout, :stderr, :exitcode)

  # The settings every command runs under: no confirmation questions, abort early
  # on errors, and no progress rendering. A cmdlet that renders a progress bar
  # (Get-FileHash, Invoke-WebRequest, Copy-Item of anything large) writes that
  # rendering into the response when it is run over a shell rather than a console,
  # and the control characters in it make the reply impossible to parse: the call
  # comes back as a WinRM transport error quoting an illegal character, with none
  # of the streams and no exit code to read. Nothing asked of Hyper-V over WinRM
  # has a use for a progress bar.
  SHELL_SETTINGS = [
    "$ConfirmPreference = 'None'",
    "$ErrorActionPreference = 'Stop'",
    '$PSNativeCommandUseErrorActionPreference = $true',
    "$ProgressPreference = 'SilentlyContinue'"
  ].join('; ').freeze

  # A host name carries letters, digits, dots and hyphens — including IPv4 and
  # bracketed IPv6 literals — and nothing else. Every shell metacharacter,
  # space, colon, slash and quote is outside this shape by construction, so a
  # value that matches it can neither break out of a quoted PowerShell string
  # nor redirect a URI. The length bound is DNS's own.
  SAFE_HOST_SHAPE = /\A(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)\z/

  # Check if the PowerShell version is newer than the value specified
  # @param version [String] a semver version to check if powershell matches
  # @returns [Boolean] is the running PowerShell newer than the given version
  def ps_version?(version)
    Gem::Version(version) >= Gem::Version("#{ps_version[:major]}.#{ps_version[:minor]}")
  end

  # Run a command on the Hyper-V system
  # @param cmd [String] the PowerShell command to execute
  # @param _skip_json [Boolean] should the return data be returned as-is, instead of being sent as JSON
  # @param _target_computer [String,nil] the computer to execute the command on, in case of clustering
  # @param options [Hash] the options to call the command with
  # @option options [Integer] _json_depth (1) the depth to limit the JSON object to on return
  # @return [Hash] the returned object from PowerShell
  def run_cmd(cmd, _skip_json: false, _target_computer: nil, **options)
    _json_depth = options.delete(:_json_depth) { 1 }

    run_cmdlist([[cmd, options.dup]], skip_json: _skip_json, json_depth: _json_depth, target_computer: _target_computer)
  end

  # Run a list of commands on the Hyper-V system
  # @param commands [Array<Array(String,Hash)>] a list of commands with their arguments to run
  # @param skip_json [Boolean] should the return value be given as-is, instead of being sent as JSON
  # @param target_computer [String,nil] the computer to execute the command on, in case of clustering
  # @param separate_calls [Boolean] should the commands be run separately
  # @param options [Hash] additional options for the call
  # @option options [Integer] json_depth (1) the depth to limit the JSON object to on return
  def run_cmdlist(commands, skip_json: false, target_computer: nil, separate_calls: false, **options)
    target_computer = [target_computer].flatten.compact
    target_computer << '.' if target_computer.empty?

    json_depth = options.delete(:json_depth) { 1 }

    Fog::Logger.debug "run_cmdlist given unknown meta-arguments: #{options.keys.join ', '}" if options.any?

    out = nil
    target_computer.each do |computer|
      connection(computer).shell(:powershell) do |shell|
        pscalls = commands.map.with_index do |(command, args), idx|
          last = idx == commands.size - 1
          build_pscall(command, _to_json: last && !skip_json, _json_depth: json_depth, **args)
        end
        pscalls = [pscalls.join("\n")] unless separate_calls

        pscalls.each_with_index do |cmd, idx|
          Fog::Logger.debug "PS; >>> \"#{cmd.split("\n").join("\n\t")}\""

          # The settings ride along inside the first run rather than getting a run
          # of their own: ruby-winrm charges a command and a receive for every
          # shell.run, so on a high-latency path the separate setup call was a
          # second of wire per call before anything was asked. The settings are
          # assignments, they print nothing, and the shell keeps them between runs
          # the way the separate call left them for every run that followed.
          out = shell.run(idx.zero? ? "#{SHELL_SETTINGS}; #{cmd}" : cmd)
          Fog::Logger.debug "PS; <<< OUT=[#{out.stdout.inspect}] ERR=[#{out.stderr.inspect}] EXIT=[#{out.exitcode}]"

          is_success = true
          is_success = shell.run('$?').stdout.strip.downcase == 'true' if out.stderr.include? 'FullyQualifiedErrorId'

          raise Fog::Hyperv::Errors::PSError.new(out, "When executing #{cmd}") if
            out.exitcode != 0 || !is_success
        end
      end
    end

    return out if skip_json
    return nil if out.stdout.strip.empty?

    json = Fog::JSON.decode(out.stdout)
    Fog::Hyperv.uncamelize(json)
  end

  # Perform a WQL query against the Hyper-V system
  # @param query [String] the query to perform
  # @param _namespace [String] the namespace to perform the call in
  # @param where [Hash] the WHERE arguments to add to the query
  # @return [Hash] the return hash from the WQL query
  def run_wql(query, _namespace: 'root/virtualization/v2', **where)
    args = Fog::Hyperv.camelize(where).reject { |k, v| v.nil? || v.is_a?(FalseClass) || k.to_s.start_with?('_') }.map do |k, v|
      "#{k} = #{((v.is_a?(String) || v.to_s =~ /\s/) && v.inspect) || v}"
    end

    query = "#{query}#{" WHERE #{args.join ' AND '}" unless args.none?}"

    Fog::Logger.debug "WQL; in #{_namespace} >>> #{query}"
    data =
      if local?
        raise NotImplementedError, 'Not implemented for local connection'
        # run_cmd('Get-WmiObject', query:, namespace:, _return_fields: options.keys)
      else
        @connection.run_wql(query, "#{_namespace}/*")[:xml_fragment].first
      end
    Fog::Logger.debug "WQL; <<< #{data}"

    data
  end

  private

  def version
    @version ||= begin
      run_wql('SELECT Version FROM Win32_OperatingSystem', _namespace: 'root/cimv2')[:version]
    rescue StandardError
      run_cmd(
        <<~CMD,
          $VMMS = if ([environment]::Is64BitProcess) {
            "$($env:SystemRoot)\\System32\\vmms.exe"
          } else {
            "$($env:SystemRoot)\\Sysnative\\vmms.exe"
          }
          (Get-Item $VMMS).VersionInfo.ProductVersion"
        CMD
        _skip_json: true,
        _ps_version: 1
      ).stdout.strip
    end
  end

  def ps_version
    @ps_version ||= run_cmd('$PSVersionTable.PSVersion', _ps_version: 1)
  end

  def build_pscall(command, _by_id: nil, _return_fields: nil, _always_include: [], **options)
    _ps_version = options.delete(:_ps_version) { ps_version[:major] }
    _to_json = options.delete(:_to_json) { true }
    _json_depth = options.delete(:_json_depth) { 1 }

    pipeline = []
    pipeline << "Where-Object {$_.id -eq '#{_by_id}'}" if _by_id
    pipeline << "Select #{Fog::Hyperv.camelize([_return_fields].flatten).join ','}" if _return_fields
    pipeline << "ConvertTo-Json -Compress#{" -Depth #{_json_depth}" if _json_depth}" if _to_json

    invalid_opts = options.select { |k, _| k.to_s.start_with? '_' }
    Fog::Logger.debug "build_pscall given unexpected meta-arguments: #{invalid_opts.keys.join ', '}" if invalid_opts.any?

    options.reject! { |k, _| k.to_s.start_with?('_') }
    options.reject! do |k, v|
      !_always_include.include?(k) && (v.nil? || v.is_a?(FalseClass) || k.to_s.start_with?('_') || (v.is_a?(String) && v.empty?))
    end
    options = Fog::Hyperv.camelize(options.compact)

    command += ' @Args' unless command.include? '@Args'
    pipeline = [command] + pipeline
    Fog::Hyperv::Utils::Powershell.build_call(pipeline.join(' | '), options, _ps_version: _ps_version)
  end

  # True when a dotless name addresses the machine a registered host is on:
  # either it is that host exactly, or it is the host's FIRST LABEL. The label
  # rule is what the scan always meant — hyperv is how someone types
  # hyperv.lab.example — and it is deliberately not start_with?: under plain
  # prefix matching the name local routes to the localhost sentinel and hyp
  # routes to the endpoint, which are not node addresses. The sentinels are
  # excluded from the label rung entirely: localhost is a name only its own
  # machine answers to, and a first-label rule over it would admit
  # localhost.evil.example on a label match.
  def host_matches?(wanted, registered_host)
    return true if registered_host == wanted

    return false if %w[. localhost].include?(registered_host) || wanted.include?('.')

    registered_host.split('.').first == wanted
  end

  # True only when the machine behind a name is known to answer on it: the
  # endpoint this instance was configured with, the sentinels that mean it, one
  # of the aliases connect() registered for it, or a short name addressing a
  # node under a registered host. The comparison is exact for anything with a
  # dot in it and case-insensitive throughout; a dotless name matches a
  # registered host only as its first label.
  def endpoint_in_endpoint_set?(name)
    return false unless name.is_a?(String) && !name.strip.empty?

    wanted = name.strip.downcase
    return true if %w[. localhost].include?(wanted)

    unless @hyperv_endpoint.nil?
      endpoint_host = URI.parse(@hyperv_endpoint.to_s).host.to_s.downcase
      return true if host_matches?(wanted, endpoint_host)
    end

    @connections.each do |c_host, c_connection|
      next if c_host.nil?
      return true if host_matches?(wanted, c_host.to_s.downcase)

      pair_host = URI(c_connection.instance_variable_get(:@connection_opts)[:endpoint]).host.to_s.downcase
      next if pair_host.empty?
      return true if host_matches?(wanted, pair_host)
    end
    false
  rescue URI::Error
    false
  end

  # A name with a shell metacharacter in it is refused wherever it is read, even
  # when it would be refused a moment later anyway: the refusal must not depend
  # on which endpoint happens to prefix-match.
  def shell_safe_host?(host)
    host.is_a?(String) && host.length <= 253 && SAFE_HOST_SHAPE.match?(host)
  end

  # The refusal for a name this instance may never speak to. The message quotes
  # only the asked-for name — never any text that came back from a machine, and
  # not the configured names either, which are this instance's own business.
  # The name goes through String#inspect: a value carrying a newline could
  # otherwise forge extra lines wherever this error is logged. The text rides
  # in stderr because that is where PSError reads its message from, and the
  # exit code is the 1 a cmdlet that refuses its argument answers with.
  def refuse_unknown_host!(host)
    raise Fog::Hyperv::Errors::PSError.new(
      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new(
        '',
        "Refusing to connect to #{host.inspect}: it is neither the configured endpoint, nor one " \
        'of the names registered for it, nor a node under either. A client connects only to the ' \
        'endpoint it was configured with and the names discovered for that endpoint.',
        1
      ),
      'When connecting to a host outside the configured endpoint set'
    )
  end

  def connection(host)
    # The set check is the FIRST statement of this method, before the
    # completion scan below. Every value that reaches this method comes from a
    # caller that can carry user-controlled data — the target computer of a
    # command, or the computer_name a lazy load carries — and nothing below
    # this line may run for a name outside the configured set: not the scan,
    # not the completion, not endpoint_for.
    if host.nil? || host.to_s.strip.empty?
      # A bare call is the documented "configured endpoint" call (a command
      # with no target computer); it carries no name to check.
      host = '.'
    elsif !%w[. localhost].include?(host.to_s.strip) && (!shell_safe_host?(host) || !endpoint_in_endpoint_set?(host))
      refuse_unknown_host!(host)
    end

    # The cache scan, on the same matching rule as the set check above: a name
    # that passed the check finds its connection here by exactly the same
    # comparisons, so nothing routes through a looser second door.
    existing = @connections.find do |c_host, c_connection|
      host_matches?(host.downcase, c_host.to_s.downcase) ||
        host_matches?(host.downcase, URI(c_connection.instance_variable_get(:@connection_opts)[:endpoint]).host.to_s.downcase)
    end

    if existing
      # The cache stores the connection, never the [key, connection] pair that
      # find returns: a pair stored under a short name was read back by the
      # next scan as if it were a connection, and the method call it answered
      # with was made against an Array.
      @connections[host] = existing.last unless @connections.key? host
      return existing.last
    end

    if %w[. localhost].include? host
      endpoint = @hyperv_endpoint
    else
      unless host.include? '.'
        # Reaching here means the name is already in the set — an alias
        # discovery registered — so the completion resolves within the set. A
        # short name that is NOT in the set was refused above: no completion
        # attempt is ever made for it.
        host = run_cmd("[System.Net.Dns]::GetHostByName(#{host.inspect})", _return_fields: :host_name, _ps_version: 1)[:host_name]
      end
      endpoint = endpoint_for(host)
    end

    existing = @connections.find do |_, c_connection|
      c_connection.instance_variable_get(:@connection_opts)[:endpoint] == endpoint
    end

    if existing
      # The pair-store rule again: the value stored is the connection itself,
      # so the next scan reads back what it expects.
      @connections[host] = existing.last unless @connections.key? host
      return existing.last
    end

    connect(endpoint)
  end

  # Builds the WinRM endpoint another machine answers on: the configured endpoint's
  # scheme, port and path with its host replaced by this one.
  #
  # Only hosts that passed connection()'s endpoint-set check reach this as a dial
  # target; the derivation itself — and the pair it produces, once connected — is
  # what makes a cluster that runs WinRM over HTTPS on 5986 manageable at all:
  # assuming http on 5985 would send a plain request to a port nothing is
  # listening on there.
  #
  # @param host [String] the machine to point the endpoint at
  # @return [String] a WinRM endpoint for that machine
  def endpoint_for(host)
    return "http://#{host}:5985/wsman" if @hyperv_endpoint.nil?

    configured = URI.parse(@hyperv_endpoint)
    # URI#port answers the scheme's default when the configured endpoint left it out,
    # which is the port any other WinRM listener answers on too; the scheme and the
    # path (/wsman for every listener) carry over as they were.
    "#{configured.scheme}://#{host}:#{configured.port}#{configured.path}"
  end

  # Builds the options WinRM::Connection is created with.
  #
  # Everything that only means something to a TLS listener - the verification
  # override, the trust store, the client certificate - is left out of a plain
  # http endpoint's options, where nothing on the other end could honour it.
  # Peer verification is on by default: an https endpoint without it encrypts
  # the conversation but never says who is at the other end, which over a
  # routed path is encryption that buys nothing. ruby-winrm only acts on
  # :no_ssl_peer_verification, so leaving it absent is how verification stays on.
  def winrm_connection_opts(endpoint)
    opts = {
      endpoint: endpoint,
      transport: @hyperv_transport,
      user: @hyperv_username,
      password: @hyperv_password,
      realm: @hyperv_realm
    }

    # The Kerberos service principal is built from this as "<service>/<host>@<realm>",
    # and the gem refuses a kerberos connection that names no service at all — so a
    # realm alone, which is all the Kerberos option has ever carried, could never
    # authenticate. WinRM listeners answer to WSMAN; hyperv_service covers the rare
    # listener published under a different principal.
    opts[:service] = @hyperv_service || 'WSMAN' if @hyperv_transport == :kerberos

    if URI.parse(endpoint).scheme.to_s.casecmp('https').zero?
      opts[:no_ssl_peer_verification] = true unless @hyperv_ssl_verify
      opts[:ca_trust_path] = @hyperv_ca_trust_path if @hyperv_ca_trust_path
      opts[:client_cert] = @hyperv_client_cert if @hyperv_client_cert
      opts[:client_key] = @hyperv_client_key if @hyperv_client_key
      opts[:key_pass] = @hyperv_key_pass if @hyperv_key_pass
    end

    # Absent is the gem's own default; these are only said when asked for.
    opts[:operation_timeout] = @hyperv_operation_timeout if @hyperv_operation_timeout
    opts[:receive_timeout] = @hyperv_receive_timeout if @hyperv_receive_timeout
    opts[:retry_limit] = @hyperv_retry_limit if @hyperv_retry_limit
    opts[:retry_delay] = @hyperv_retry_delay if @hyperv_retry_delay

    opts
  end

  # The names a machine answers to on the network: its own short name and the
  # fully qualified one DNS gives it, read off the same $env:computerName and so
  # asked for in one call - each shell.run is a command and a receive on the
  # wire, and a connection that is brand new was paying for two of them before
  # it could answer anything.
  #
  # @param fqdn [String] the host the connection was made to, to ask on
  # @return [Array(String,nil)] the short name and the resolved one, either nil
  #   when the machine reported nothing for it, or answered nothing at all
  def discover_host_names(fqdn)
    names = run_cmd(
      '"$($env:computerName); $([System.Net.Dns]::GetHostByName($env:computerName).Hostname)"',
      _target_computer: fqdn,
      _skip_json: true,
      _ps_version: 1
    ).stdout.to_s.lines.first.to_s.split(';', 2).map { |name| name.strip.downcase }.map { |name| name unless name.empty? }
    names
  rescue StandardError => e
    # GetHostByName throws on a machine whose own name does not resolve, and the
    # shell's Stop preference turns that into a raised PSError. The extra names
    # are worth one call, not a refused connection: the connection is already
    # registered under the endpoint's own name, so a host that will not answer
    # for its names loses the aliases and nothing else
    Fog::Logger.debug "host name discovery on #{fqdn} failed: #{e.message}"
    [nil, nil]
  end

  def connect(endpoint = nil)
    endpoint ||= @hyperv_endpoint
    fqdn = URI.parse(endpoint).host

    opts = winrm_connection_opts(endpoint)

    Fog::Logger.debug "Creating WinRM connection with #{opts.merge password: '<REDACTED>', key_pass: '<REDACTED>'}"
    require 'winrm'

    connection = WinRM::Connection.new opts
    connection.logger.level = :error
    @connections[fqdn] = connection

    # Add the local host's names to the connection; discovery answers nil for a
    # host that will not answer, so the connection stands either way
    hostname, resolved = discover_host_names(fqdn)
    @connections[hostname] ||= connection if hostname
    if resolved
      @connections[resolved] ||= connection
      fqdn = resolved
    end

    if endpoint == @hyperv_endpoint
      @connection = connection
      @connections['.'] = connection
      @connections['localhost'] = connection
      @local_hostname = hostname
    end

    connection
  end
end
# rubocop:enable Metrics/ModuleLength
