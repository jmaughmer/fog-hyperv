# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/contained_path'

    # Delete one file that lives inside a directory the caller names, and answer
    # whether there was anything to delete.
    #
    #   remove_file(path: 'C:\ClusterStorage\Volume1\foreman-bootdisk\6\1c51c4ee\full-host.iso',
    #               root: 'C:\ClusterStorage\Volume1', computer_name: 'hv-node2')
    #
    # This is remove_item's job plus the two things remove_item could not give a
    # caller that repeats itself:
    #
    # One — absence is an answer, not a failure. remove_item renders Remove-Item
    # with no existence guard, and this transport turns any non-zero exit into
    # Fog::Hyperv::Errors::PSError: measured on the lab node, Remove-Item of a
    # missing path raised even with -ErrorAction SilentlyContinue. A caller that
    # cleans up the same path twice — a bootdisk ISO removed by the machine's own
    # teardown and then again by the janitor — therefore failed the second time,
    # and could not tell "already gone" from "could not delete" without reading
    # error text. The verdict here is a boolean: true deleted something, false
    # found nothing to delete.
    #
    # Two — the scope is explicit. root is a location that reached fog as a
    # string from a caller's configuration, and ContainedPath refuses before any
    # traffic every path that could not be honoured as one literal file inside
    # it, including a root that is blank or relative and a path that steps outside
    # its root. Without that, an unset or over-wide store setting turns "delete
    # this machine's file" into a delete somewhere on the volume.
    #
    # The existence test and the deletion share one script (see
    # ContainedPath.build_file_removal_script), so there is no round trip and no
    # window between them, and a folder is refused rather than deleted: whether a
    # folder's contents go with it is a scope decision, and a request named
    # remove_file does not take it silently.
    #
    # No Mock of its own, like remove_item: the fork's mutating requests are
    # exercised against a recording client, not against Fog.mock!.
    def remove_file(path:, root:, computer_name: nil, **_options)
      contained = Fog::Hyperv::Utils::ContainedPath.validate_contained_path!(path, __method__)
      anchor = Fog::Hyperv::Utils::ContainedPath.validate_root!(root, __method__)
      Fog::Hyperv::Utils::ContainedPath.validate_contained!(contained, anchor, __method__)

      out = run_cmd(Fog::Hyperv::Utils::ContainedPath.build_file_removal_script(contained),
                    _skip_json: true, _target_computer: computer_name)

      # The script prints exactly one of the two marker lines and nothing else, so
      # any other body — empty, a stray object, a warning that reached stdout — is
      # an answer this contract does not describe, and deleting again on the
      # strength of it is not safe.
      case out.stdout.to_s.strip
      when 'REMOVED=true' then true
      when 'REMOVED=false' then false
      else
        raise Fog::Hyperv::Errors::RemovalVerdictUninterpretable,
              "the file removal printed #{out.stdout.to_s.inspect}; it prints REMOVED=true or " \
              'REMOVED=false and nothing else, so whether anything was deleted is unknown'
      end
    end
  end
end
