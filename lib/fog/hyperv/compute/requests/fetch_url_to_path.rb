# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/contained_path'
    require 'fog/hyperv/utils/file_pull'

    # Pull a URL down to one literal path on the host, verify it, and only then
    # let it wear that path.
    #
    #   fetch_url_to_path(url: 'http://foreman/bootdisk-pull/<32-hex-nonce>.iso',
    #                     path: 'C:\ClusterStorage\Volume1\foreman-bootdisk\6\...\full-host.iso',
    #                     sha256: 'e3b0c442...', size: 245_000_000)
    #   # => 245000000
    #
    # The host pulls over HTTP instead of the caller pushing base64 through
    # WinRM: spike 0.1 measured the push at 0.54-0.75 MB/s against the host's
    # pull at 148.9 MB/s for the same file. What the authenticated WinRM push
    # got for free, the anonymous GET has to check for itself, and the request
    # carries the expectations for exactly that — the caller's sha256 and byte
    # count travel over WinRM (the authenticated channel), never in the URL.
    #
    # The script behind this asks status 200 first (a 3xx under
    # -MaximumRedirection 0 is not trusted to throw on its own), then size, then
    # host-side sha256 — all while the file is still <path>.part — and only then
    # Move-Item -Force onto the final name, so a truncated or redirected body
    # never presents as the complete ISO a later step will mount. Every failure
    # path removes the .part and rethrows, so what is left on disk after a
    # refusal is what was there before it.
    #
    # Refusals before any traffic: a path that is not one literal absolute
    # location (the same refusers remove_file answers with), a URL that is not
    # http(s), a sha256 that is not 64 hex digits, a size that is not a positive
    # Integer. Answers the pulled byte count; a stdout the script could not have
    # printed raises PullVerdictUninterpretable rather than being read as a
    # successful pull.
    #
    # No Mock, like remove_file: the answer is a marker the script prints, not a
    # drive shape a fixture could carry.
    def fetch_url_to_path(url:, path:, sha256:, size:, computer_name: nil, **_options)
      raise ArgumentError, "url must be an http(s) URL the host can reach; got #{url.inspect}" unless url.to_s.match?(%r{\Ahttps?://})

      dest = Fog::Hyperv::Utils::ContainedPath.validate_contained_path!(path, __method__)

      raise ArgumentError, "sha256 must be 64 hex digits; got #{sha256.inspect}" unless sha256.to_s.match?(/\A[0-9a-fA-F]{64}\z/)
      raise ArgumentError, "size must be a positive Integer; got #{size.inspect}" unless size.is_a?(Integer) && size.positive?

      out = run_cmd(
        Fog::Hyperv::Utils::FilePull.build_script(url: url, path: dest, sha256: sha256, size: size),
        _skip_json: true,
        _target_computer: computer_name
      )

      # The script's last act prints PULLED=<bytes> and nothing else can reach
      # stdout behind it — any other body means the script did not run to the end
      # of its checks, and a caller that staged on the strength of it would be
      # betting on a pull this request cannot describe.
      case out.stdout.to_s.strip
      when /\APULLED=(\d+)\z/
        Regexp.last_match(1).to_i
      else
        raise Fog::Hyperv::Errors::PullVerdictUninterpretable,
              "the pull printed #{out.stdout.to_s.inspect}; it prints PULLED=<bytes> and nothing else, " \
              'so how many verified bytes landed is unknown'
      end
    end
  end
end
