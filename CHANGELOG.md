## Unreleased

- Ask another node of a cluster on the endpoint it actually answers, rather
  than plain http on port 5985 of the configured host: a cluster that secures
  WinRM over HTTPS on 5986 could not be managed at all, because the second
  node got a request to a port nothing listens on and the failure arrived as a
  transport error naming a host nobody typed
- Make a virtual machine highly available, and take it back out: Add and
  Remove ClusterVirtualMachineRole requests that run on the node owning the
  machine, and a ClusterVirtualMachineRole can be read by the GUID of the
  machine it was made for, because the removal cmdlet only answers by machine
- Say which node a machine is really on: Server#owner_node reads the machine's
  cluster role rather than the node the machine was read from, which goes
  stale when a role moves, with Server#clustered? and #cluster_role behind it.
  Cluster#nodes gives the cluster's own view of its nodes — state, votes,
  drain — without opening a shell on every one the way Cluster#hosts does
- Read a cluster's networks and how it votes: Cluster#networks says which node
  has a path onto each shared subnet, and Cluster#quorum is where "will this
  cluster survive losing that node" starts
- Read which node owns each clustered virtual machine: Cluster#roles answers a
  ClusterVirtualMachineRole per clustered machine with its OwnerNode, because
  Get-VM answers only for the node it ran on and loses sight of a machine the
  moment its role fails over
- Read a cluster's shared volumes and the disks left to make more from:
  Cluster#shared_volumes and #available_disks, which is what placement onto
  cluster storage has to know before it can offer a destination
- Answer a miss in a collection with NotFound instead of a TypeError: a get
  that found nothing merged nil into new, so every caller asking "is this
  thing gone" got what read like a broken transport, in every collection in
  the gem and not only clusters
- Reload a cluster from what Get-Cluster actually returns: a single match is a
  Hash and several are an array, and neither has #attributes, so Cluster#reload
  raised NoMethodError against a real host
- Let a mocked client answer clusters at all: mocked requests read their mock
  files (the filters were passed in the wrong place, and every request without
  a Mock of its own raised instead of answering), filter by the same ids and
  names the real requests filter by, Get-VMHost answers for the machine it was
  asked about rather than always the fixture's first, and valid? and
  supports_clusters? answer instead of not existing, which is what lets a
  consumer's cluster gating be tested

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
