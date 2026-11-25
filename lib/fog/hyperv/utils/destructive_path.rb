# frozen_string_literal: true

require 'fog/hyperv/utils/ps_quote'

module Fog
  module Hyperv
    module Utils
      # The checks every path handed to a destructive cmdlet has to pass before
      # it goes on the wire, and the one script that removes a machine folder,
      # which is the only delete here that has to decide about a directory.
      #
      # Why it is strict: Remove-Item's -Path is wildcard semantics, measured —
      # a machine named web[12] is legal on NTFS, passes any equality check this
      # side can run, and reaches the host as a character class: -Recurse
      # -Force then deletes the sibling folders web1 and web2 and leaves
      # web[12] standing. -LiteralPath binds no wildcard at all, so a path that
      # contains wildcard characters cannot be honoured even by the fixed
      # render — it has to be refused, because "delete web[12]" as a literal is
      # not what the old -Path render did, and quietly narrowing an operator's
      # request is not this side's call to make either. The same reasoning
      # covers the folder: Test-Path answers $false for an access-denied or
      # unreadable folder exactly as it answers for an empty one, so the old
      # "Test-Path root\* is false, so Remove-Item -Recurse" guard failed open
      # into a recursive delete. A folder is removed here only on the strength
      # of an enumeration that ran, succeeded, and found nothing.
      module DestructivePath
        module_function

        # PowerShell's wildcard set, the same one -Path expands. NTFS forbids
        # * and ? in names outright but permits [ and ] — which is exactly why
        # the realistic shape is a legal machine name like web[12] rather than
        # anything exotic: brackets are what an operator's VM name list
        # actually looks like.
        WILDCARD_CHARS = /[*?\[\]]/

        # One path naming one location, returned as given. Anything else —
        # blank, a list (the "#{path}.*" sibling glob destroy used to send), a
        # non-string, or a name carrying * ? [ ] — is refused here, before any
        # traffic, naming the request that asked.
        def validate_destructive_path!(value, request)
          unless value.is_a?(String)
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} takes one path as a string and got #{value.class}; a list of paths is a " \
                  'deletion scope this method will not take responsibility for'
          end

          if value.strip.empty?
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses an empty path: nothing was named, so nothing may be deleted"
          end

          if value.match?(WILDCARD_CHARS)
            raise Fog::Hyperv::Errors::InvalidDestructivePath,
                  "#{request} refuses a path containing the wildcard characters * ? [ ]: -LiteralPath " \
                  'binds them as no file at all while -Path expanded them into a set — ask for one ' \
                  'exact location instead'
          end

          value
        end

        # The machine-folder cleanup, as one raw script: enumerate first, delete
        # only on a found-nothing answer. No -Recurse: the scope being taken is
        # exactly "a folder this enumeration just proved empty", and anything
        # that appears between the count and the delete is then refused by
        # Remove-Item itself instead of swept up. The shell's Stop preference
        # (the settings every run carries) turns a failed enumeration — missing,
        # locked, access denied — into a raised PSError, so "could not look" is
        # never read as "nothing there". The path is validated here too, so no
        # caller can reach the quoted literal without passing the checks above;
        # every character the PowerShell tokenizer ends a single-quoted literal
        # at — the apostrophe and the four Unicode single quotes — doubles up,
        # which is the whole of what such a literal needs (backslashes are not
        # special inside it, and these are Windows paths).
        def build_empty_folder_removal_script(path)
          literal = Fog::Hyperv::Utils::PsQuote.escape(validate_destructive_path!(path, 'the folder cleanup'))

          "$children = @(Get-ChildItem -LiteralPath '#{literal}' -Force); " \
            "if ($children.Count -eq 0) { Remove-Item -LiteralPath '#{literal}' -Force }"
        end
      end
    end
  end
end
