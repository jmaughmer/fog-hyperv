# frozen_string_literal: true

module Fog
  module Hyperv
    module Utils
      # One owner for rendering a value as a WQL literal, so every site that
      # embeds caller data into a WQL query embeds it the same way. The job
      # is defined by the grammar of the engine THIS gem dials (Microsoft
      # WQL over WinRM), measured on HV-CL01 through this gem's own run_wql
      # path on 2026-11-26 — parse acceptance, read-only SELECTs:
      #
      #   1. String literals are delimited by DOUBLE QUOTES ONLY. A
      #      single-quoted literal — even WHERE Caption = 'Hosting Computer
      #      System' — is refused outright (WSMan fault 2150858778 =
      #      WBEM_E_INVALID_QUERY). The DMTF CQL grammar (DSP0202), which
      #      also allows ' literals and doubles them as its only escape, is
      #      NOT the dialect this engine speaks.
      #   2. Inside "..." a BACKSLASH is the escape character: \\ is a
      #      literal backslash and \" a literal double quote, while a
      #      backslash before anything else (\S, \t) is an invalid escape
      #      the engine refuses. A value ending in a single backslash would
      #      escape its own closing delimiter and run the literal into the
      #      rest of the WHERE clause — the collapse class this owner exists
      #      to close.
      #   3. An apostrophe inside "..." is plain content: no doubling, no
      #      escape. (The five-quote story lives in PsQuote; it belongs to
      #      the PowerShell tokenizer, not to WQL.)
      #   4. A raw control byte (a real TAB) parses inside the literal, but
      #      no legitimate comparison value — GUID, device name, FQDN,
      #      version — carries one, and single-line queries keep the debug
      #      log honest, so control characters are refused here rather than
      #      embedded.
      #
      # The String#inspect that stood here before FOG-34 happened to share
      # this grammar's delimiters and backslash escapes, but it is Ruby's
      # grammar overall: it rewrites control characters into \t text (an
      # invalid escape the engine refuses), escapes #{ as \#{ for Ruby's
      # sake, and renders non-Strings unquoted ("WHERE Name = 2026-11-26
      # 12:00:00 +0000"). Those values produced queries the provider
      # refused at round-trip cost; they are refused HERE, before the wire.
      module WqlQuote
        CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/
        # A WQL property name is [A-Za-z][A-Za-z0-9_]*. **where binds
        # Symbols, but a Symbol can carry ANY text (:"a OR 1=1"), so the
        # shape is enforced here rather than trusted.
        COLUMN_NAME = /\A[A-Za-z][A-Za-z0-9_]*\z/

        class << self
          # The column name as it may be interpolated into a WHERE clause:
          # whatever camelize produced, if it is not a bare property name it
          # is refused — the key position has no quoting grammar to hide
          # structure in.
          def column(name)
            str = name.to_s
            return str if str.match?(COLUMN_NAME)

            raise ArgumentError,
                  "WqlQuote.column refuses #{str.inspect} as a WQL property name; " \
                  'a key that is not a bare [A-Za-z][A-Za-z0-9_]* name is ' \
                  'injection, not a column'
          end

          # The value as it must appear INSIDE a double-quoted WQL literal:
          # backslashes escaped first, then double quotes — one pass each,
          # in that order, so the escape never escapes itself. A non-string
          # is refused rather than stringified — PsQuote's rule: a value
          # that is not text has a caller that should have rendered it
          # deliberately.
          def escape(value)
            unless value.is_a?(String)
              raise ArgumentError,
                    "WqlQuote.escape embeds one string and got #{value.class}; " \
                    'a value that is not text has no string-literal rendering'
            end

            if value.match?(CONTROL_CHARACTERS)
              raise ArgumentError,
                    'WqlQuote.escape refuses control characters; no legitimate ' \
                    'WQL comparison value carries one, and embedding them asks ' \
                    'the query for bytes the caller cannot see'
            end

            value.gsub('\\') { '\\\\' }.gsub('"') { '\"' }
          end

          # The string AS a double-quoted WQL literal: the escape, wrapped.
          def quote(value)
            "\"#{escape(value)}\""
          end

          # The value AS a whole WQL literal: text rides double-quoted;
          # Integer, Float, true and false ride bare (measured here: bare
          # integers and TRUE/true/FALSE/false parse). Anything else —
          # Symbol, Time, nil — is refused: it has no WQL literal
          # rendering, and guessing one (a Time's default to_s, say) emits
          # an unquoted multi-word clause the engine refuses after a wire
          # round trip. Bare Floats ride Float#to_s as at base; that form
          # (NaN, 1.0e+16) parses or does not parse exactly as the engine
          # decides, which for those forms it does not — loudly, at the
          # provider, not quietly as a wrong query.
          def literal(value)
            case value
            when String then quote(value)
            when Integer, Float, true, false then value.to_s
            else
              raise ArgumentError,
                    "WqlQuote.literal renders text, numbers and booleans; #{value.class} " \
                    'has no WQL literal rendering and was refused rather than guessed at'
            end
          end
        end
      end
    end
  end
end
