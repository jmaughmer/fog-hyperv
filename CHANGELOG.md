## Unreleased

- Recognise hyperv_ssl_verify, hyperv_ca_trust_path, hyperv_client_cert,
  hyperv_client_key and hyperv_key_pass, and give hyperv_transport the
  transport that authenticates by certificate to speak
- Verify the TLS peer of an https endpoint by default, which the connection
  used to switch off unconditionally. This changes behaviour for an https
  endpoint with a certificate the trust store does not answer for: it fails
  instead of connecting, and wants hyperv_ca_trust_path pointing at the CA
  that issued it or hyperv_ssl_verify: false to say otherwise. Encryption
  that never says who is at the other end is not protection on a routed path
- Default the transport to kerberos when a realm is given and to ssl when a
  client certificate is given, before falling back to negotiate: ruby-winrm's
  negotiate always wraps NTLM tokens and NTLM is deprecated by its vendor
  with disabling it the stated end state, so the transports that do not speak
  it should not need to be asked for by name

## v0.2.2 2026-11-16

- Fix valid? and supports_clusters? always returning false for remote hosts,
  run_wql already returns the first instance so re-reading xml_fragment off it
  never worked, which made connection validation and the UI test button fail
- Require the version file, Fog::Hyperv::VERSION was undefined unless the
  gemspec happened to load it
- Fix DvdDrive#create reading a controller_numbere that does not exist, which
  raised NoMethodError before anything was sent to Hyper-V and made attaching an
  image to a machine through the model impossible
- Give PSError a message when PowerShell reports nothing, which is what a cmdlet
  that found nothing to act on does: the exit code is what gets the call raised,
  and a message of nil turned every report of that failure into a NoMethodError
- Turn off progress rendering in the PowerShell shell. A cmdlet that renders a
  progress bar writes that rendering into the WinRM response, where its control
  characters make the reply impossible to parse and the call comes back as a
  transport error quoting an illegal character instead of anything about itself

## v0.2.1 2026-11-15

- Add missing runtime dependency on the logging gem
- Fix undefined variable in the service connection cache

## v0.2.0 2026-06-11

- Add support for managing integration services
- Fix modification of Firmware
- Remove empty VHD directory on destroy
- Fix detection of empty key protector
- Remove VM-specific config directory on destroy

## v0.1.1 2026-05-22

- Add support for Ruby 3.0

## v0.1.0 2026-05-21

- Major rewrite of the codebase, moving to handling objects by GUID as far as possible
- Add support for renaming of VMs, NICs, and Switches
- Add support for optimizing and resizing VHDs
- Improve support for VLAN configuration on NICs
- Extract more useful metadata from Hyper-V objects

## v0.0.9 2018-05-15

- Add support for Fog-Core v2.0+

## v0.0.8 2018-04-06

- Fix issues due to a lost `to_s` call
- Fix enum handling
- Improve Ruby 2.4 support
- Add support for baking PS option maps in commands
- Default to using the cluster if one, and only one, is available
- Support adding legacy network adapters

## v0.0.7 2018-01-22

- Add a temporary VM-wide VLAN assignment method
- Add the missing SetVM-NetworkAdapterVlan file

## v0.0.6 2018-01-15

- Ensure that computer and cluster names are always present in collections
- Allow caching direct assignment of computer/cluster
- More enum fixes to standardise key and value types
- Add a check for cluster support
- Make sure to not pass along internal variables to the PSRemoting shell

## v0.0.5 2017-11-14

- Remove lefover debugging outputs

## v0.0.4 2017-11-14

- Adds support for the Kerberos transport
- Implements a first prototype for multi-hop when not using Kerberos/CredSSP
- Fixes issues in the saving of a few models
- Fixes a major issue when a VM ends up in a state with a large numerical value
  - An issue in the enum code made input validity checking unable to differentiate between hashes and arrays

## v0.0.3 2017-08-30

- Fixes handling of BIOS/Firmware
- Skips unnecessary Hyper-V calls when checking dirty status
- Adds some possible interface improvements when dealing with clusters

## v0.0.2 2017-08-28

- Reduces `fog-core` dependency to 1.42
- Disables `status` attribute for network adapters, due to Hyper-V 6.3 issues

## v0.0.1 2017-08-25

- Initial release
