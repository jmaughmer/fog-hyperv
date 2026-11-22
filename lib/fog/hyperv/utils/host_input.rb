# frozen_string_literal: true

require 'uri'

module Fog
  module Hyperv
    module Utils
      # The rule every HOST-shaped input is checked against: the shape a host
      # may have, and the endpoints a host name may compose. It lives here, as
      # pure functions with no connection to consult, for two reasons. The
      # first is that the rule has exactly one owner: the option that composes
      # an endpoint and the gate in front of the connection cache ask the same
      # function, so no value can be a legal host at one door and a payload at
      # the other. The second is that a caller can then ask whether the rule is
      # the one it expects, without a machine to talk to — a capability probe
      # is one call into this module.
      #
      # Why the shape is an allowlist: a host name is read as a URI and, before
      # this PR, was once interpolated into a remote PowerShell string too.
      # Everything a shell or a URI gives special meaning to — $, backtick,
      # semicolon, space, quotes, pipes — is outside the shape by construction,
      # so a value that answers to it can neither break out of a render nor
      # redirect an endpoint. A bare IPv6 literal is in, brackets and all.
      module HostInput
        module_function

        # DNS's own ceiling on a name's length; anything longer is not a host
        # someone typed, it is a payload wearing one.
        MAX_HOST_LENGTH = 253

        # A host name carries letters, digits, dots and hyphens — including
        # IPv4 and bracketed IPv6 literals — and nothing else. It must start
        # and end with a letter or a digit, so a leading hyphen cannot be read
        # as an option and a trailing dot cannot smuggle a name's owner.
        SAFE_HOST_SHAPE = /\A(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)\z/

        # True for a name that can name a machine and nothing else.
        def valid_host_input?(value)
          value.is_a?(String) &&
            !value.empty? &&
            value.length <= MAX_HOST_LENGTH &&
            SAFE_HOST_SHAPE.match?(value)
        end

        # One host name, returned as given. Anything else is refused here, by
        # name of the request that asked, with the value quoted (inspect) and
        # never interpolated: a refusal that pasted the payload into its own
        # sentence would say the payload twice.
        def validate_host_input!(value, request)
          return value if valid_host_input?(value)

          raise Fog::Hyperv::Errors::InvalidHostInput,
                "#{request} takes one host name or address and got #{value.inspect}: letters, digits, " \
                'dots and hyphens (or a bracketed IPv6 literal), up to 253 characters, and nothing ' \
                'a shell or a URI reads as special'
        end

        # One WinRM endpoint, returned as given. The checks run before anything
        # parses or dials it: a host inside a URI gets the same rule as a bare
        # one, the scheme has to be one a WinRM listener answers on (the
        # transport is said by hyperv_transport, not smuggled into the URL),
        # and an unqualified name on https is refused outright — a certificate
        # subject and a Kerberos service principal are host-qualified, and the
        # remote name completion this gem used to run answered exactly such a
        # name by silently building a plain http endpoint for it.
        def validate_endpoint!(value, request)
          unless value.is_a?(String)
            raise Fog::Hyperv::Errors::InvalidHostInput,
                  "#{request} takes one endpoint URL and got #{value.inspect}"
          end

          uri = begin
            URI.parse(value)
          rescue URI::Error
            raise Fog::Hyperv::Errors::InvalidHostInput,
                  "#{request} got #{value.inspect}, which is not a URL a WinRM endpoint can be"
          end

          scheme = uri.scheme.to_s
          unless scheme.casecmp('http').zero? || scheme.casecmp('https').zero?
            raise Fog::Hyperv::Errors::InvalidHostInput,
                  "#{request} got #{value.inspect}: a WinRM listener answers on http or https, " \
                  'and the authentication transport is set by hyperv_transport, not by the scheme'
          end

          host = uri.host
          if host.nil? || host.empty?
            raise Fog::Hyperv::Errors::InvalidHostInput,
                  "#{request} got #{value.inspect}, which names no host to connect to"
          end
          validate_host_input!(host, "#{request} host (in #{value.inspect})")

          if scheme.casecmp('https').zero? && !host.include?('.')
            raise Fog::Hyperv::Errors::InvalidHostInput,
                  "#{request} got #{value.inspect}: an unqualified host on https carries no certificate " \
                  'subject and no Kerberos service principal that means what it says — name the machine ' \
                  'the way it is named in its own certificate'
          end

          value
        end
      end
    end
  end
end
