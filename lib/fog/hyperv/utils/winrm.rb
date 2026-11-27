# frozen_string_literal: true

require 'fog/json'
require 'fog/hyperv/utils/ps_quote'
require 'fog/hyperv/utils/wql_quote'

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

  # PowerShell renders the warning, verbose, debug and information streams onto
  # the shell's stdout, and run_cmdlist reads stdout as the JSON payload. That
  # is not theoretical: measured on a live cluster, Add-ClusterVirtualMachineRole
  # SUCCEEDED — group created, VM intact — and fog raised DecodeError quoting
  # 'Warning:' at line 1, because the cmdlet's remote-execution advisory printed
  # before the payload; Stop-ClusterNode rendered roughly 29 such lines in one
  # call. Windows PowerShell 5.1 cannot merge those streams into stderr —
  # measured on the lab node, `cmd 3>&2` is a parse error ("The '3>&2' operator
  # is reserved for future use", and the parse failure itself then exits 0, so
  # it would have silently emptied every reply). What 5.1 does take is merging
  # each stream into the success stream, so these redirects ride the rendered
  # cmdlet call together with the ADVISORY_ROUTER below, which pulls the
  # records back out. The success stream is deliberately absent from the
  # merges — the payload must stay where it is.
  STREAM_REDIRECTS = ' 3>&1 4>&1 5>&1 6>&1'

  # The merge above is version-gated (review F5): the Information stream and
  # its 6> redirect operator exist only from PowerShell 5.0, and on anything
  # older the appended 6>&1 is a PARSE ERROR for the whole rendered script —
  # which, per the measurement above, exits 0 with $? true and an empty
  # reply, so every read looks empty and every write looks successful. The
  # 3>&1 4>&1 5>&1 merges are valid from PowerShell 3, which is the floor
  # this fork's own fixtures assume (BuildNumber 9600, Server 2012 R2, is the
  # cluster fixture in test/unit/compute/cluster_test.rb).
  LEGACY_STREAM_REDIRECTS = ' 3>&1 4>&1 5>&1'

  # The router the merged advisories land in front of. Warning/verbose/debug/
  # information records are identified by their exact types (all four measured
  # on the lab node under n>&1) and handed to the host's error-line channel —
  # $Host.UI.WriteErrorLine was measured to arrive on the WinRM stderr an
  # operator reads, without producing an error record: it leaves $? true and
  # adds no FullyQualifiedErrorId, so fog's own error detection cannot mistake
  # an advisory for a failure. Everything else passes through untouched, and
  # when no advisory fires the router is invisible. The console-style TYPE:
  # prefix keeps each line as readable as the bare stdout render was.
  # InformationRecord is a separate arm because it (like 6>&1) does not exist
  # before PowerShell 5.0 — naming an unresolvable type in -is is documented
  # to make PS 4 write a runtime error per piped object and drop it, so the
  # legacy router must not mention it. (No PS 4 host is in the lab; the
  # design is robust either way — the legacy router simply never names the
  # type.)
  ADVISORY_ROUTER_HEAD = 'ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord] ' \
                         '-or $_ -is [System.Management.Automation.VerboseRecord] ' \
                         '-or $_ -is [System.Management.Automation.DebugRecord]'

  ADVISORY_ROUTER_TAIL = ') ' \
                         "{ $Host.UI.WriteErrorLine($_.GetType().Name.Replace('Record', '').ToUpper() + ': ' + $_.ToString()) } " \
                         'else { $_ } }'

  ADVISORY_ROUTER = "#{ADVISORY_ROUTER_HEAD} -or $_ -is " \
                    '[System.Management.Automation.InformationRecord]' \
                    "#{ADVISORY_ROUTER_TAIL}".freeze

  LEGACY_ADVISORY_ROUTER = "#{ADVISORY_ROUTER_HEAD}#{ADVISORY_ROUTER_TAIL}".freeze

  # A verb-noun cmdlet name and nothing else: the only source shape the merge
  # and router may follow. It excludes the expressions the version and
  # discovery probes are ('$PSVersionTable.PSVersion' starts with a dollar) and
  # every multi-statement or argument-bearing raw script, which are left
  # exactly as they were — claiming to clean those would be a false
  # advertisement, and the requests all live on the cmdlet-call side.
  CMDLET_SOURCE = /\A[A-Z][A-Za-z0-9]*-[A-Za-z0-9-]*\z/

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

        pscalls.each_with_index do |pscall, idx|
          # Joining the pscall here repairs a latent flaw of separate_calls:
          # per-call pscalls are Arrays, and the first method call below used
          # to get one. The stream redirects this PR adds ride the rendered
          # cmdlet call inside the pscall (see build_pscall), not a wrap here:
          # PowerShell 5.1 only accepts a redirect on a command invocation, and
          # the settings below must stay at session scope, which a wrap would
          # also have broken.
          script = Array(pscall).join("\n")
          Fog::Logger.debug "PS; >>> \"#{script.split("\n").join("\n\t")}\""

          # The settings ride along inside the first run rather than getting a run
          # of their own: ruby-winrm charges a command and a receive for every
          # shell.run, so on a high-latency path the separate setup call was a
          # second of wire per call before anything was asked. The settings are
          # assignments, they print nothing, and the shell keeps them between runs
          # the way the separate call left them for every run that followed.
          out = shell.run(idx.zero? ? "#{SHELL_SETTINGS}; #{script}" : script)
          Fog::Logger.debug "PS; <<< OUT=[#{out.stdout.inspect}] ERR=[#{out.stderr.inspect}] EXIT=[#{out.exitcode}]"

          is_success = true
          is_success = shell.run('$?').stdout.strip.downcase == 'true' if out.stderr.include? 'FullyQualifiedErrorId'

          raise Fog::Hyperv::Errors::PSError.new(out, "When executing #{script}") if
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
      # FOG-34: the value rides a WQL literal, which before this line it did
      # not: String#inspect is Ruby's grammar, not this engine's — it
      # rewrites control characters into \t text and #{ into \#{, both
      # invalid escapes Microsoft WQL refuses at the provider, and it
      # renders non-Strings unquoted ("WHERE Name = 2026-11-26 12:00:00
      # +0000"). All of that is refused here instead, before the wire. The
      # key is no guarantee either: **where binds Symbols, but a Symbol can
      # carry any text (:"a OR 1=1"), so its shape is enforced, not trusted.
      "#{Fog::Hyperv::Utils::WqlQuote.column(k)} = #{Fog::Hyperv::Utils::WqlQuote.literal(v)}"
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

  # The names THIS endpoint reported for itself at connect, downcased —
  # the machine's short name and its own fully qualified name, whichever
  # arrived (see discover_host_names: the connection asked even before
  # FOG-27; FOG-27 only keeps the answer). This is the endpoint's SELF
  # report, for callers that must match a node name against "the machine
  # behind this client": matched as a node name, the URL host of an IP
  # endpoint like 10.0.0.5 reduces to its first label — '10' — and a
  # CNAME names no node at all. [] until the endpoint connection stands,
  # and [] forever for a host that will not answer for itself — the
  # caller degrades to the URL, it never fails and is never left to
  # guess. Frozen and shared: the answer belongs to the connection, not
  # to any one caller.
  #
  # @return [Array(String)] the names the endpoint answered for itself
  def local_host_names
    @local_host_names
  end

  private

  def version
    @version ||= begin
      run_wql('SELECT Version FROM Win32_OperatingSystem', _namespace: 'root/cimv2')[:version]
    rescue StandardError
      # The hand-written fallback that answers when the WQL query above
      # cannot. Its last line reached this fork as
      # `(Get-Item $VMMS).VersionInfo.ProductVersion"` — closing a double
      # quote it never opened, a parse error for the whole script on the
      # very fallback whose job is to answer when parsing WQL was not the
      # option. It ends its statement now.
      run_cmd(
        <<~CMD,
          $VMMS = if ([environment]::Is64BitProcess) {
            "$($env:SystemRoot)\\System32\\vmms.exe"
          } else {
            "$($env:SystemRoot)\\Sysnative\\vmms.exe"
          }
          (Get-Item $VMMS).VersionInfo.ProductVersion
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
    pipeline << "Where-Object {$_.id -eq '#{Fog::Hyperv::Utils::PsQuote.escape(_by_id.to_s)}'}" if _by_id
    # The projection rides single-quoted literals, one per field, with the
    # commas OUTSIDE them — argument-mode bare words already parsed as
    # exactly these strings, so every existing caller asks for what it
    # always asked for and only the bytes move. What cannot happen now: a
    # field value carrying one of the five literal-ending quotes closing its
    # own word mid-pipeline, or a `;` composing a second statement. PsQuote
    # is the one owner of the doubling inside the literal, same as every
    # other single-quoted site.
    if _return_fields
      fields = Fog::Hyperv.camelize([_return_fields].flatten)
                          .map { |field| Fog::Hyperv::Utils::PsQuote.quote(field.to_s) }
                          .join(',')
      pipeline << "Select #{fields}"
    end
    # -Depth is documented as the integer it now renders: to_i means no
    # arriving value, string or otherwise, can append a statement to the
    # pipeline this stage exists to contain. Every caller in the repo rides
    # the default 1, which renders byte for byte as before.
    pipeline << "ConvertTo-Json -Compress#{" -Depth #{_json_depth.to_i}" if _json_depth}" if _to_json

    invalid_opts = options.select { |k, _| k.to_s.start_with? '_' }
    Fog::Logger.debug "build_pscall given unexpected meta-arguments: #{invalid_opts.keys.join ', '}" if invalid_opts.any?

    options.reject! { |k, _| k.to_s.start_with?('_') }
    options.reject! do |k, v|
      !_always_include.include?(k) && (v.nil? || v.is_a?(FalseClass) || k.to_s.start_with?('_') || (v.is_a?(String) && v.empty?))
    end
    # The compact here used to drop the very nils the reject above had just
    # protected: _always_include said "send this key", compact said "nil never
    # ships", and the host got a cmdlet call with the caller's verb missing
    # (measured: an eject rendered without any Path answered the drive still
    # mounted). Only nils _always_include did not claim are droppable now; a
    # claimed nil reaches the JSON parameter round-trip Powershell.build_call
    # renders through, where ConvertFrom-Json materialises it as a $null-valued
    # hashtable entry and the @Args splat binds it as the -Name $null the caller
    # asked for.
    options = Fog::Hyperv.camelize(options.reject { |k, v| v.nil? && !_always_include.include?(k) })

    command += ' @Args' unless command.include? '@Args'
    # The merge and the router ride the rendered cmdlet call itself and go on
    # ahead of the rest of the pipeline, so the advisories the cmdlet writes are
    # pulled out of the stream before Where/Select/ConvertTo-Json ever see
    # them, and stdout carries only the payload. An expression like
    # $PSVersionTable.PSVersion, and a raw script, match nothing here and
    # render exactly as they used to. The pair is version-gated (review F5):
    # below PowerShell 5.0 the 6>&1 would break the parse of the whole call
    # (exit 0, empty reply — the silent-empty mode this fork measured), so a
    # pre-5 host gets the PS3-era merge and the router that names only the
    # three record types that exist there. _ps_version defaults to the PROBED
    # major, so a real 2012 R2 endpoint answers 4 once and every later call
    # takes the legacy path on its own.
    if CMDLET_SOURCE.match?(command.sub(/ @Args\z/, ''))
      if _ps_version.to_i >= 5
        command += STREAM_REDIRECTS
        pipeline.unshift(ADVISORY_ROUTER)
      else
        command += LEGACY_STREAM_REDIRECTS
        pipeline.unshift(LEGACY_ADVISORY_ROUTER)
      end
    end
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
  # on which endpoint happens to prefix-match. The rule is HostInput's — the
  # very one the builder validator uses for the options that compose an
  # endpoint — so no value is a legal host at one door and a payload at the
  # other, and a probe of HostInput.valid_host_input? is a probe of both.
  def shell_safe_host?(host)
    Fog::Hyperv::Utils::HostInput.valid_host_input?(host)
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
    # The set check is the FIRST statement of this method. Every value that
    # reaches this method comes from a caller that can carry user-controlled
    # data — the target computer of a command, or the computer_name a lazy load
    # carries — and nothing below this line may run for a name outside the
    # configured set: not the scan, not the composition, not endpoint_for.
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
      # FOG-9 removed the remote GetHostByName completion that used to sit
      # here. It was the one place a host string became remote PowerShell
      # text, and it answered unqualified names with a silently-composed
      # plain http endpoint. No name is completed on a machine's say-so
      # anymore: what passed the set check above goes forward verbatim, and
      # the only FQDN-ization left is Ruby's own resolver on this side of the
      # wire. One composition is refused outright: an unqualified name on a
      # TLS endpoint, because a certificate subject and a Kerberos service
      # principal are host-qualified — the same refusal the builder makes of
      # a configured endpoint that names a machine that way.
      unless host.include?('.')
        scheme = @hyperv_endpoint.nil? ? 'http' : URI.parse(@hyperv_endpoint).scheme.to_s
        if scheme.casecmp('https').zero?
          raise Fog::Hyperv::Errors::InvalidHostInput,
                "connection refuses #{host.inspect} on a TLS endpoint: an unqualified name carries no " \
                'certificate subject and no Kerberos service principal that means what it says'
        end
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
  # The resolution rides inside its own try (FOG-29): a machine whose own name
  # does not resolve answers that arm empty and STILL answers the short name.
  # One throw used to take both names down with it, and the alias the short
  # name carries is the one an IP- or CNAME-addressed endpoint needs most.
  #
  # @param fqdn [String] the host the connection was made to, to ask on
  # @return [Array(String,nil)] the short name and the resolved one, either nil
  #   when the machine reported nothing for it, the FQDN also when the machine's
  #   own name does not resolve, or both when nothing came back — a blank answer
  #   or a call that died outright
  def discover_host_names(fqdn)
    names = run_cmd(
      '$fogShort = $env:computerName; ' \
      'try { $fogFq = [System.Net.Dns]::GetHostByName($env:computerName).Hostname } ' \
      "catch { $fogFq = '' }; " \
      '$fogShort + "; " + $fogFq',
      _target_computer: fqdn,
      _skip_json: true,
      _ps_version: 1
    ).stdout.to_s.lines.first.to_s.split(';', 2).map { |name| name.strip.downcase }.map { |name| name unless name.empty? }
    names
  rescue StandardError => e
    # FOG-29 contained the resolution inside the script, so a raise here is the
    # CALL dying (transport, shell), not a name that would not resolve. The
    # extra names are worth one call, not a refused connection: the connection
    # is already registered under the endpoint's own name, so a host whose
    # answer cannot be read loses the aliases and nothing else
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
      # FOG-27: keep the discovery ANSWER, not only its side effects. This
      # is the endpoint's own report of which machine it is — the short
      # name and the name it resolves to, downcased, exactly as
      # discover_host_names answered them, nothing asked that the
      # connection did not already learn. Callers that must decide whether
      # a node name IS this machine need these: a URL host of 10.0.0.5
      # names the machine to the network and to nobody else. Reassigned
      # whole and frozen, so a caller can read the list without copying it
      # and no later connect mutates what an earlier reader holds.
      @local_host_names = [hostname, resolved].compact.uniq.freeze
    end

    connection
  end
end
# rubocop:enable Metrics/ModuleLength
