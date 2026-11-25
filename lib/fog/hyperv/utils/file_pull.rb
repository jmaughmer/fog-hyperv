# frozen_string_literal: true

require 'fog/hyperv/utils/ps_quote'

module Fog::Hyperv
  module Utils
    # The pull script behind fetch_url_to_path (:file_pull).
    #
    # Spike 0.1 measured why the pull exists: base64-pushing the built ISO
    # through WinRM runs 0.54-0.75 MB/s (5.2-7.2 min per host, with a 16 MB
    # chunk faulting in pwrshplugin.dll), while the Hyper-V host pulling the
    # same file over HTTP ran 148.9 MB/s (1.6 s). Pulling also changes who to
    # trust: the WinRM channel was authenticated, the HTTP GET is anonymous, so
    # the integrity checks ride on the pull itself — and their ORDER is the
    # contract (round 10, F3):
    #
    #   1. StatusCode -eq 200 first. -MaximumRedirection 0 is asked not to
    #      follow redirects, but the script does not trust a 3xx body to throw
    #      on its own — the status is read from the -PassThru response.
    #   2. Size, then host-side sha256, both against the caller's expectations
    #      — which travel over WinRM, the authenticated channel, not in the URL.
    #   3. Only then Move-Item the .part onto the final name. A truncated or
    #      redirected body therefore never wears the name the caller will mount.
    #
    # $ProgressPreference is silenced before the download because PowerShell
    # 5.1's progress bar measurably throttles Invoke-WebRequest; a script whose
    # whole reason to exist is speed does not pay for a progress bar.
    module FilePull
      class << self
        # One script; stdout ends in PULLED=<bytes> and nothing else. Every
        # failure path funnels through the same catch: delete the .part (it is
        # this script's own trash, never the caller's final file) and rethrow,
        # so the transport surfaces WHICH check said no.
        def build_script(url:, path:, sha256:, size:)
          quoted_url = Fog::Hyperv::Utils::PsQuote.escape(url)
          quoted_path = Fog::Hyperv::Utils::PsQuote.escape(path)

          <<~SCRIPT
            $ProgressPreference = 'SilentlyContinue'
            $fogPart = '#{quoted_path}.part'
            try {
              $fogResp = Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -PassThru -OutFile $fogPart -Uri '#{quoted_url}'
              if ($fogResp.StatusCode -ne 200) {
                throw ("fetch_url_to_path refuses: the pull answered HTTP " + $fogResp.StatusCode + ', only 200 carries the ISO')
              }
              $fogBytes = (Get-Item -LiteralPath $fogPart).Length
              if ($fogBytes -ne #{size}) {
                throw ("fetch_url_to_path refuses: the pull is " + $fogBytes + ' bytes; expected #{size}')
              }
              $fogHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fogPart).Hash
              if ($fogHash -ne '#{sha256.upcase}') {
                throw ("fetch_url_to_path refuses: the pull's sha256 is " + $fogHash + ', expected #{sha256.upcase}')
              }
              Move-Item -LiteralPath $fogPart -Destination '#{quoted_path}' -Force
            } catch {
              Remove-Item -LiteralPath $fogPart -Force -ErrorAction SilentlyContinue
              throw
            }
            Write-Output "PULLED=$fogBytes"
          SCRIPT
        end
      end
    end
  end
end
