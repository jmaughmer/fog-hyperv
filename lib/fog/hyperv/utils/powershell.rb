# frozen_string_literal: true

require 'fog/json'
require 'fog/hyperv/utils/ps_quote'

module Fog::Hyperv::Utils::Powershell
  # Build a Powershell option map from a set of keyword arguments
  # @param _optmap_name [String] the name of the option map to generate
  # @param _ps_version [Integer] the major version of PowerShell to generate the option map for
  # @param _from_json [Boolean] should the option map be built from JSON data
  # @param options [Hash] the options to convert into a PowerShell option map
  def self.build_optmap(_optmap_name: 'FogArgs', _ps_version: 5, _from_json: true, **_options)
    ps_opts = Fog::Hyperv.camelize(_options)
    if _from_json
      # The payload is JSON, which escapes everything EXCEPT the quote
      # characters this embedding rides — a name carrying an apostrophe (or a
      # typographic one, which the tokenizer treats identically) would else
      # end the literal and run the rest of the argument as code. Backslashes
      # are left exactly as the JSON encoder wrote them: a single-quoted
      # literal does not process them, and ConvertFrom-Json expects the
      # encoder's own doubling.
      json = Fog::Hyperv::Utils::PsQuote.escape(Fog::JSON.encode(ps_opts))
      if _ps_version >= 6
        ["$#{_optmap_name} = ConvertFrom-Json -AsHashtable '#{json}'"]
      else
        [
          [
            "$FogJsonObject = '#{json}'",
            '$FogJsonParameters = ConvertFrom-Json -InputObject $FogJsonObject',
            "$#{_optmap_name} = @{}",
            "$FogJsonParameters.psobject.properties | Foreach { $#{_optmap_name}[$_.Name] = $_.Value }"
          ].join('; ')
        ]
      end
    else
      args = ps_opts.map do |k, v|
        # Unqualified on purpose: shell_quote lives in THIS module, and the
        # Fog::Hyperv-qualified call was a leftover from before the utils
        # split — every argument in this branch made it a NoMethodError, and
        # no caller had ever reached this line (FOG-23's render test is the
        # first). The branch's own $-interpolation semantics inside its
        # double-quoted values are upstream behaviour this repo leaves
        # alone. Below this first call sit the Array and non-scalar arms:
        # they called shell_quoted, a name this repo has not defined since
        # the rewrite that moved this quoting into Utils deleted it and left
        # those two calls behind (e6a1410), so an Array or Integer option
        # died with a NameError before a single
        # argument shipped (round-24 F1) — FOG-31's recursion to shell_quote
        # itself is that repair, so every value type this branch documents
        # now renders instead of dying.
        "'#{k}'=#{shell_quote(v, always: true)}"
      end

      ["$#{_optmap_name} = @{#{args.join ';'}}"]
    end
  end

  # Build a Powershell cmdlet call
  # @param cmdlet [String] the PowerShell cmdlet to call
  # @param args [Hash] the argument to call the cmdlet with
  # @param _ps_version [Integer] the major version of PowerShell the call is being made for
  #
  # @example Running a simple cmdlet
  #   build_call 'Get-VM', { name: 'example VM' }, _ps_version: 7
  #   => "$Fogwozmqayrgsyd = ConvertFrom-Json -AsHashtable '{"Name": "example VM"}\nGet-VM @Fogwozmqayrgsyd"
  def self.build_call(cmdlet, args = {}, _ps_version: 5)
    return [cmdlet.gsub('@Args', '')].flatten if args.empty?

    id = (cmdlet.hash ^ args.hash).abs.to_s(36)
    optmap = "Fog#{id}"

    commands = []
    commands += build_optmap(_optmap_name: optmap, _ps_version: _ps_version, **args)
    commands << if cmdlet.include? '@Args'
                  cmdlet.gsub('@Args', "@#{optmap}")
                else
                  "#{cmdlet} @#{optmap}"
                end
    commands
  end

  # Convert Ruby data to PowerShell equivalents
  # @param data [Object] the Ruby data to convert
  # @param always [Boolean] should the data be included even if the equivalent would be a no-op
  def self.shell_quote(data, always: false)
    case data
    when String
      if !data.start_with?('$') && (data =~ /(^$)|\s/ || always)
        data.gsub('`', '``')
            .gsub(/\0/, '`0')
            .gsub("\n", '`n')
            .gsub("\r", '`r')
            .inspect
            .gsub('\"', '`"')
            .gsub('\\\\', '\\')
      else
        data
      end
    when Hash
      raise 'Hashes need to be run through build_optmap'
    when Array
      # The first of the two arms that never ran (round-24 F1): this called
      # shell_quoted, a name this file has called ever since the utils
      # rewrite (e6a1410) deleted the definition and left the calls behind,
      # so every Array option died with NameError before a single argument
      # shipped. The
      # recursion both dead arms meant is shell_quote itself — the same
      # owner the String, boolean and null arms already ride — so elements
      # quote through the one method that owns quoting, and a Hash inside
      # an Array meets this guard's own refusal instead of a NameError.
      "@(#{data.map { |e| shell_quote(e, always: true) }.join(', ')})"
    when FalseClass
      '$false'
    when TrueClass
      '$true'
    when nil
      '$null'
    else
      # The second dead arm, repaired by the same one-word recursion. An
      # Integer reaches the String arm as its own digits, which neither
      # need quoting nor a space: the option receives a number, not a
      # numeric string.
      shell_quote data.to_s
    end
  end
end
