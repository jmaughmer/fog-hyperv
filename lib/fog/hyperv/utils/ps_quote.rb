# frozen_string_literal: true

module Fog
  module Hyperv
    module Utils
      # One owner for the escape a PowerShell single-quoted literal needs, so
      # every site that embeds text into '...' embeds it the same way. Two
      # tokenizer facts define the job, and the per-site gsubs that stood here
      # before each got one of them wrong:
      #
      #   1. The tokenizer ends a single-quoted literal at the four Unicode
      #      single quotes — U+2018 LEFT, U+2019 RIGHT, U+201A LOW-9, U+201B
      #      HIGH-REVERSED-9 — exactly as it ends it at the ASCII apostrophe.
      #      Doubling only the ASCII one let a URL or device name carrying a
      #      typographic quote close its own literal and run the rest of the
      #      string as code under the WinRM account.
      #   2. Backslashes are NOT special inside a single-quoted literal, and
      #      JSON-encoded payloads have already doubled the ones their own
      #      grammar needs. A "fix" that doubled backslashes here would make
      #      ConvertFrom-Json answer a different path than the caller named,
      #      so this escape deliberately passes them through untouched.
      #
      # What survives is exactly the doubling: each of the five quote
      # characters becomes two of itself, the one substitution the tokenizer
      # turns back into one character of the value.
      module PsQuote
        # The five characters that end a single-quoted literal. Named once,
        # listed in the same order the tests iterate.
        QUOTE_CHARS = ["'", "\u2018", "\u2019", "\u201A", "\u201B"].freeze

        QUOTE_PATTERN = Regexp.union(QUOTE_CHARS).freeze

        class << self
          # The value as it must appear INSIDE a single-quoted literal, with
          # every literal-ending character doubled. A non-string is refused
          # rather than stringified: this method's whole job is the safety of
          # an embedded value, and `nil.to_s` embedding as the empty literal
          # would silently ask for "the machine named nothing".
          def escape(value)
            unless value.is_a?(String)
              raise ArgumentError,
                    "PsQuote.escape embeds one string and got #{value.class}; " \
                    'a value that is not text has no single-quoted rendering'
            end

            value.gsub(QUOTE_PATTERN) { |quote| quote * 2 }
          end

          # The value AS a single-quoted literal: the escape, wrapped.
          def quote(value)
            "'#{escape(value)}'"
          end
        end
      end
    end
  end
end
