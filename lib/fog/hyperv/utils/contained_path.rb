# frozen_string_literal: true

require 'fog/hyperv/utils/ps_quote'

module Fog
  module Hyperv
    module Utils
      # The checks a path has to pass before it is honoured as ONE location
      # inside a directory the caller names as its root, and the script that
      # removes exactly such a file.
      #
      # Why this sits beside DestructivePath rather than inside it:
      # DestructivePath answers "does this name one exact location", which every
      # destructive request already asks. Containment answers a different
      # question — "is that location inside the scope the caller is allowed to
      # touch" — and only the requests whose root arrives as a string from a
      # caller's configuration can ask it. The realistic failure is not an
      # attacker but an operator setting: a bootdisk store that reaches fog as
      # `C:\` widens "delete this machine's ISO" to a delete on the volume root,
      # and a path built by concatenating a GUID or a name into that setting can
      # step outside its root without anyone typing `..`.
      #
      # The accepted characters are the Foreman side's SAFE_PATH set
      # (foreman_hyperv/lib/foreman_hyperv/input_validation.rb: letters, digits,
      # space, dot, dash, underscore, colon, backslash) plus the single quote,
      # which NTFS allows in a name and which the removal script escapes by
      # doubling. Matching that set is not decoration. Everything else outside it
      # is either something PowerShell re-expands before the cmdlet sees it —
      # `$` inside a double-quoted string, a backtick as the escape character,
      # `;` and `|` as statement separators, `<` and `>` as redirection — or
      # something that makes a containment answer unreliable: `/` is a real NTFS
      # separator, so a comparison that looked only at `\` would let `C:/Windows`
      # satisfy a prefix match on `C:\Windows`. Wildcards are refused by
      # DestructivePath, which is re-run here so no caller can reach a script
      # with a half-checked path.
      module ContainedPath
        module_function

        # An absolute Windows location: `D:\…`, or a UNC share `\\server\share\…`.
        # `C:foo` is NOT absolute — it is drive-relative and resolves against the
        # virtual-machine service process's current directory, so it names no
        # fixed place and cannot be compared against a root.
        ABSOLUTE = /\A(?:[A-Za-z]:\\|\\\\)/

        # The path characters the removal script can render without the shell
        # re-reading them, plus the doubled single quote (see above).
        ALLOWED_CHARS = /\A[\p{L}\p{N} .\-_:\\']+\z/

        # One path naming one location, returned as given: DestructivePath's
        # whole answer (blank, non-string, list, wildcard), then the three things
        # only containment cares about — the location is absolute, it carries no
        # unresolved `..`, and no separator arrives in a form the root
        # comparison would not see.
        def validate_contained_path!(value, request)
          Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(value, request)

          unless value.match?(ALLOWED_CHARS)
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses a path outside the accepted characters " \
                  "(letters, digits, space, . - _ : \\ and '): $ and a backtick are expanded by the " \
                  'shell, ; | < > would end the statement, and / is a real NTFS separator a containment ' \
                  'comparison on \\ alone would not see'
          end

          unless value.match?(ABSOLUTE)
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses a path that is not absolute: `#{value}` names no fixed place — " \
                  'C:foo is drive-relative and resolves against the service process current directory'
          end

          # Same reason the root refuses it, and the caller-side reason is
          # sharper: the literal string IS the name a caller will mount or
          # delete next, and an unresolved `..` means the host resolves that
          # name somewhere else than the string says.
          if value.split('\\').include?('..')
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses `..` in a path: nothing on this side resolves it, so the literal " \
                  'location the caller names and the one the host lands on are not the same place'
          end

          value
        end

        # The same refusal for the root, which is the operator-supplied half and
        # therefore the likelier of the two to arrive blank, relative, or with a
        # stray wildcard. `..` is refused here rather than resolved: nothing on
        # this side knows the host's file system, and a root whose own position
        # depends on the process's current directory anchors nothing.
        def validate_root!(value, request)
          Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(value, request)

          unless value.match?(ALLOWED_CHARS) && value.match?(ABSOLUTE)
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} takes the directory it may work inside as an absolute path and got " \
                  "`#{value.inspect}`; a relative or unanchored root contains nothing"
          end

          if segments(value).include?('..')
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses `..` in its root: the directory it names is not fixed until the " \
                  'process current directory is known'
          end

          value
        end

        # True when path is root or lives beneath it, compared the way NTFS
        # compares names — case- and separator-insensitive — and requiring a
        # separator boundary, because `C:\store-old\a.iso` starts with `C:\store`
        # as a string and is not inside it. Neither side may carry a `..`
        # segment: neither is resolved, so an unresolved `..` is a location this
        # comparison cannot trust and the answer is simply "not contained".
        def contained?(path, root)
          path = normalize(path)
          root = normalize(root)
          return false if path.nil? || root.nil?
          return false if path.split('\\').include?('..') || root.split('\\').include?('..')

          path == root || path.start_with?("#{root}\\")
        end

        # Refuse, naming both sides, unless the path is inside the root.
        def validate_contained!(path, root, request)
          unless contained?(path, root)
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses #{path} because it is neither #{root} nor inside it: the root is " \
                  'the scope this request may touch, and a path outside it names something the caller ' \
                  'never meant to reach'
          end

          path
        end

        # Remove one file inside a root, as ONE raw script: the existence test
        # and the deletion share a run, so there is no round trip and no window
        # between them. Absent answers REMOVED=false and no error — the caller
        # asks for a file to be gone, and a file that is already gone satisfies
        # that, which is what a retried or repeated cleanup needs. A folder is
        # REFUSED, not deleted: whether a directory's contents go with it is the
        # scope decision DestructivePath exists to make explicitly, and a request
        # named remove_file must not take it silently. The shell's Stop
        # preference (SHELL_SETTINGS on every run) turns anything Remove-Item
        # still fails on — access denied, a file the guest holds open — into a
        # raised PSError, so no -ErrorAction is needed and none is used. The path
        # is validated by the caller before it gets here; single quotes inside a
        # name double up, the only escape a single-quoted literal needs.
        def build_file_removal_script(path)
          quoted = Fog::Hyperv::Utils::PsQuote.quote(validate_contained_path!(path, 'the file cleanup'))

          # One assignment so the name is quoted once and the three cmdlets below
          # cannot disagree about which file they were talking about.
          <<~SCRIPT
            $fogPath = #{quoted}
            if (-not (Test-Path -LiteralPath $fogPath)) {
              'REMOVED=false'
            } elseif ((Get-Item -LiteralPath $fogPath -Force).PSIsContainer) {
              throw ('remove_file removes one file, not a folder: a folder''s contents are a scope decision it will not take')
            } else {
              Remove-Item -LiteralPath $fogPath -Force
              'REMOVED=true'
            }
          SCRIPT
        end

        def segments(value)
          value.tr('/', '\\').split('\\')
        end

        def normalize(value)
          return nil unless value.is_a?(String)

          value.tr('/', '\\').upcase.sub(/\\+\z/, '')
        end
      end
    end
  end
end
