## Unreleased

- Every single-build claim in the shipped comments now names the build its
  evidence was captured on (FOG-39, FOG-38's recorded follow-up). Thirteen
  sites across five files spoke as though the lab had one build: six said
  "the measured build" outright (the role scripts' VmID NULL home and its
  test header, the role-group naming rule, the AutoFailbackType write
  acceptance, the failback-window write refusal, and the owner-node test
  header), one used the same phrase two lines above a block that was already
  being corrected — invisible to a line-based grep, since it wrapped — and
  the rest rode on "this build", "every build", or a bare unqualified
  universal ("the direct VmID property is NULL on real machine-role groups")
  with no build at all. Each now names Server 2025 / FailoverCluster 26100,
  the build every one of those captures ran on, and the role-group naming
  rule names both builds — the 26100 capture and the 2022 / 20348 lineage's
  2026-11-27 role round trip, which produced the same bare-name group. Where
  a fact was NOT re-probed on the 2022 lineage (the direct VmID property,
  the two HA-settings writes, the HA properties as reads) the comment says
  that probe is open instead of letting the claim borrow the other build's
  measurement. One unbounded universal ("they read fine on every build") is
  now scoped to the build that measured it rather than left to inherit the
  citation beside it. Comment-only: no shipped code changed, and the suite
  answers 488 tests / 1529 assertions identically on branch and base across
  six seeds.
- `Real#supports_clusters?` now memoises its answer — true and false alike —
  for the life of the client (FOG-36, whole-fork review of 2026-11-26). The
  probe is a live `root/mscluster` WQL round trip; the FOG-28 model memos kept
  it off steady-state model calls, but every cold model's first cluster
  question still paid it, the cold classification paid it TWICE (the guard in
  `Server#cluster_queriable?` and the one inside `#cluster_role`'s cold read
  before the role lookup), and the plugin's stand-alone destroy gate asks on
  every destroy attempt against an endpoint that can never answer yes — the
  cold double-probe cost 4-9 RTT per model, and one refused probe is a full
  command group (~3-5 s of wire time at this fork's satellite budget;
  whole-fork review 2026-11-26); the memo erases every one after the first.
  (The destroy gate's own cluster-membership read is a different query with
  a different owner and keeps its dial by design.) A host's cluster
  membership does not change underneath a live client session any more than
  the endpoint identity this client already trusts for the connection's
  whole lifetime, so a host that joins or leaves a cluster mid-session keeps
  the answer it gave; rebuilding the endpoint's client (the compute-resource
  reconnect) is the re-ask. An errored first probe is remembered as the
  fail-closed `false` it already returned — the rescue cannot tell the
  measured stand-alone refusal (an answer that can never change) from a
  transport flap on a joined host (where a later ask would likely learn
  differently): both are remembered no until the client is rebuilt.
  `Mock#supports_clusters?`
  deliberately does NOT memoise: its answer is a fixture read with no wire
  cost, and the mock-based suites redefine the method to model gate flips.

- `fetch_url_to_path` now rides a per-call WinRM operation window computed
  from the `size:` it already carries (FOG-35, whole-fork review of
  2026-11-26). The window the WinRM service enforces travels in the
  `OperationTimeout` header ruby-winrm builds from the CONNECTION's
  `operation_timeout` — measured on the installed winrm-2.3.9:
  `wsmv/header.rb` `shared_headers` merges it into every message builder, and
  the gem's defaults are 60 s operation / 70 s receive, with a configured
  receive below the operation lifted to operation + 10 at build
  (`connection_opts.rb`). A fixed window therefore capped every boot-disk
  pull at window x link throughput regardless of ISO size — the review
  measured the cliff: a 245 MB ISO in the plugin's pinned 90 s needs ~2.8 MB/s
  effective, and an expiry abort mid-download bypasses the script's own
  `.part` cleanup. The request now computes `size / 1 MiB/s` — below every
  pull rate this fork has measured (the 148.9 MB/s spike ride included) —
  clamped to `[90, 3600]` seconds: the floor keeps the plugin's pinned window
  for small files, the cap bounds the COMPUTED window at an hour (3600 MiB at
  the budget — just over 3.5 GiB), and an explicitly configured longer `hyperv_operation_timeout`
  is respected above the cap — the window only ever widens what an operator
  asked for. A per-call window needs its own connection because the header is
  per-connection, so `run_cmd` gained `_operation_timeout:` routed through
  `run_cmdlist` to a new `long_operation_connection`: a lazily-built
  `WinRM::Connection` variant (no socket at build) carrying the routed base
  connection's own options with only the window widened, cached per
  endpoint-and-window, and deliberately kept OUT of the `@connections` host
  map so it can never answer a host lookup and silently move ordinary traffic
  onto a widened window. The host set-check and routing run first and
  unchanged; every call that names no window rides the configured connection
  exactly as before, and the pull still costs exactly one command round trip.
- The `run_wql` WHERE builder now renders caller values as WQL literals
  through a new single owner, `Fog::Hyperv::Utils::WqlQuote`, instead of Ruby
  `String#inspect`, and guards the key position by shape. The grammar is the
  one MEASURED on a live host through this gem's own WinRM path (2026-11-26):
  the engine this gem dials — Microsoft WQL — delimits string literals with
  double quotes only (a single-quoted literal is refused: `WBEM_E_INVALID_
  QUERY`) and honors two escapes inside them, `\\` and `\"`; a backslash
  before anything else is an invalid escape, and a value ending in a single
  backslash eats its own closing delimiter. `inspect` is Ruby's grammar: it
  happened to share the delimiter and both escapes, but it rewrites control
  characters into `\t` text and `#{` into `\#{` — both invalid escapes this
  provider refuses after a wire round trip — and it renders non-Strings
  unquoted (`WHERE Name = 2026-11-26 12:00:00 +0000`). `WqlQuote` emits
  double-quoted literals with measured escaping, passes apostrophes and
  typographic quotes as plain content, renders `Integer`, `Float` and
  booleans bare (the bare integer and TRUE/false forms measured to parse;
  Float#to_s edge forms are the provider's to refuse, loudly, as at base),
  and refuses control characters, keys that are not bare property names
  (`**where` binds Symbols, and a Symbol can carry `a OR 1=1`), and values
  with no literal rendering. One behaviour change is deliberate and stated:
  every value that is not `String`, `Integer`, `Float`, `true` or `false`,
  and every string carrying a control character, now raises `ArgumentError`
  at the caller where the base emitted a query the WMI provider refused at
  round-trip cost. No shipped caller passes `where:` values today — every
  in-repo `run_wql` call is a static query — so this is the sink pinned
  before the first dynamic caller, closing the M4 finding of the
  2026-11-26 security review.

- `Server#reload`'s return documentation now states the answers the method
  really gives. The second `@return` line promised nil "if something went
  wrong or the model was not found"; measured against the shipped read, no
  went-wrong path ever answered nil. An empty successful answer is the
  read's one nil — run_cmdlist returns it on a zero-exit, empty stdout
  before any decode. A missing `:id` raises the ArgumentError fog-core's
  `requires` throws before a wire is dialled (fog-core 2.6.0 has no
  MissingRequiredArgument class). A failed cmdlet raises
  `Fog::Hyperv::Errors::PSError` — run_cmdlist checks exitcode after every
  run, and `$?` whenever stderr carries a FullyQualifiedErrorId — while a
  transport that cannot carry the run at all raises its own error (the
  `Errno::` family or winrm-gem errors, not PSError). `reload` carries no
  rescue, so either failure propagates untouched. A deleted machine rides
  the PSError path, not nil. This is a
  documentation correction only — the method body has not moved — and it
  closes the NIT-1 finding of the FOG-28 review.

- A shared volume row that arrives as a scalar is now refused the same way
  every other off-shape capacity answer is. The capacity parser flattens the
  volumes list before validating rows — dropping nils, unwrapping lists —
  and a String, number, or boolean that survived the flattening died inside
  the row validator on its own name lookup: a TypeError from String#[] and
  Integer#[], a NoMethodError from true and false. The read escaped as that
  raw crash past ClusterCapacityUninterpretable, the one refusal class this
  read answers every other off-shape answer in and whose refusals its
  callers propagate, so a placement decision met an interpreter complaint
  instead of the interpretable refusal. The validator checks what
  a row IS first now and refuses what is not a hashtable, naming the class
  and the value that arrived. The degradation class is measured, not
  hypothetical — Server 2025 answers serialise nested objects as bare
  type-name strings (§33.1) — and no caller in this repo hands the parser a
  scalar today; the guard stands between a future degraded answer and a
  crash escaping its refusal contract. What is NOT touched: the row-content
  refusals (name, state, SharedVolumeInfo count, online-without-path), the
  witnessed-zero empty answer, and the measured flat-row happy path, all
  pinned green on both trees.

- The non-JSON option map now renders the value types it documents.
  build_optmap's _from_json: false arm was first EXECUTED by FOG-23's
  render test, and that execution only ever reached the arm's first line:
  below it, shell_quote's Array arm and its non-scalar fallback called
  shell_quoted, a name this repo has not defined since the rewrite that
  moved this quoting into Utils deleted the definition and left the calls
  behind (e6a1410), so an Array or Integer
  option died with NameError before a single argument shipped (round-24
  F1). Both dead arms now ride the one-word recursion they always meant —
  shell_quote itself, the same owner the String, boolean and null arms
  already ride. Integers render bare (an option receives a number, not a
  numeric string), Arrays render as @( ) of recursively quoted elements,
  and a Hash inside an Array meets the Hash guard's own refusal instead of
  a NameError for a call this file has never been able to resolve since
  that rewrite. What is NOT touched: the
  branch's double-quoted, $-interpolating value semantics are upstream
  behaviour and stay exactly as FOG-23 left them, and the JSON arm — the
  one every in-repo caller rides — never enters this code.

- WinRM's composed commands now embed text as data, not as syntax, in the
  three spots the composer had left bare. The version fallback — the
  hand-written script reached only when the WQL version query raises, whose
  entire job is to answer when the first arm cannot — closed a double quote
  it never opened on its last line, so the fallback arrived as a PowerShell
  parse error instead of a version; it ends its statement now. The
  _return_fields projection embedded its camelized field list as bare words
  (Select Name,Id), so a field value carrying one of the five literal-ending
  quotes would close its own word mid-pipeline and one carrying a ; would
  compose a second statement; each field now rides a single-quoted literal
  through PsQuote, the one owner of that escape, with the commas kept
  outside the literals so the argument count cannot move. Argument-mode bare
  words already parsed as exactly those strings, so every existing caller
  asks for what it always asked for — the parsed arguments are identical,
  only the rendered bytes move. And -Depth interpolated whatever object
  arrived; it now renders the integer the flag documents, so no arriving
  value can append a statement to the pipeline that stage exists to contain
  (every caller in the repo rides the default 1, which renders byte for byte
  as before). What is NOT touched: the _from_json: false option map keeps
  its double-quoted scheme and its dead shell_quoted arms exactly as FOG-23
  left them — that repair is its own feature.

- Host-name discovery now keeps the short name when the FQDN arm fails. The
  one call that asks a machine both names it answers to printed the short name
  and [System.Net.Dns]::GetHostByName's answer as one expression, so on a
  machine whose own name does not resolve — exactly the machine an IP- or
  CNAME-addressed endpoint has most reason to call by its NetBIOS name — the
  resolution threw and took the short name down with it, and later calls by
  that name met the exact-host gate with no alias behind them. The resolution
  now rides inside its own try with an empty-string catch, so a host that
  cannot resolve its own name still prints its short name and answers no
  FQDN. Still one call: no extra call, no extra command — the review's split
  probe would have cost a second command-and-receive per connection. What is
  NOT promised: a discovery CALL that dies outright (transport, shell) keeps
  anything — that answer remains no names and a connection standing on the
  endpoint's own name, exactly as before.

- The Server model's cluster memos now live the lifetime their docs promise:
  #is_clustered checks its memo BEFORE it asks whether cluster questions can
  be asked at all — that guard is a live root/mscluster round trip (Real#
  supports_clusters? dials on every check, and the guard short-circuits only
  before an id is set), and running it first billed the dial to every read
  on a model with an id, including reads of an answer the model had been
  given seconds ago. A first call still pays the probes the question needs. And
  #reload now drops the #cluster_role memo along with the tri-state's, before
  it re-reads the machine: a memo that survived reload made a model held
  across a failover keep answering owner_node with the pre-move node — the
  exact staleness #owner_node exists to avoid. The consequences are stated
  with the fix: an answer a model holds stands until reload, so a gate that
  flips afterwards does not erase it, and a reload that finds nothing also
  leaves the next cluster question to be re-asked rather than repeated.

- build_pscall now honors the _always_include promise it already made: a nil the
  caller claimed survives the arg filter and rides the JSON parameter round-trip
  the fork renders calls through, binding as -Name $null at the splat. It did not
  used to: a later compact dropped every nil regardless of the claim, so a request
  whose whole verb is a deliberate nil reached the host as a cmdlet call without
  that parameter — the PR-1 lab measurement watched eject_vm_dvd_drive answer a
  still-mounted drive, file still locked, because its -Path $null had been
  compacted away. Unclaimed nils still drop exactly as before. The blast radius
  is every model that ever sends a deliberate nil through a claimed key:
  HardDrive, ComPort and FloppyDrive #update with path = nil now send
  -Path $null where the old compact sent no -Path at all — for the DVD drive
  that null is the measured eject; for those three the null-write itself is
  not yet measured on a lab node.

- The host pulls, instead of the caller pushing: fetch_url_to_path has the
  Hyper-V host fetch an http(s) URL itself (spike 0.1 measured 148.9 MB/s against
  0.54-0.75 MB/s for a base64 push through WinRM) and puts the integrity checks the
  authenticated push got for free onto the anonymous GET, in order — HTTP 200 first,
  then the caller's byte count, then the caller's sha256 computed on the host, all
  while the file is still <path>.part, and only then Move-Item -Force onto the final
  name, so a truncated or redirected body never wears the name a later step mounts.
  Failed checks remove the .part and rethrow; any stdout other than the script's
  PULLED=<bytes> raises PullVerdictUninterpretable. The signature names the five
  keywords the script reads and takes no catch-all, so an unknown or misspelled
  keyword (computer_nmae:) raises ArgumentError at the call instead of being
  swallowed and the pull running against the default endpoint.
  Declares the :file_pull capability.

- Eject one DVD drive by Id as its own idempotent request: eject_vm_dvd_drive runs
  Set-VMDvdDrive -Path $null -Passthru against the named drive with no media or
  existence check first, so a detach that retries after an already-empty drive gets
  the same clean answer instead of a false failure; the passthru answer is the
  drive as it was BEFORE the eject — the PR-1 measurement watched an eject's answer
  carry the file the eject had just released while the next fresh read already
  answered it gone — so a caller that needs the after state re-reads the drive.
  Its Mock delegates to set_vm_dvd_drive's with path forced
  nil, and a drive the VM does not have answers nil there the way the set's does.

- Read and reorder a Gen2 VM's UEFI boot order without losing what was not asked
  for: get_vm_boot_order answers the firmware's entries as an ordered list (position,
  BootType, the Device rendering, the device Id, the File entry's FirmwarePath), and
  set_vm_boot_order takes a sequence of class names — optionally one DvdDrive named by
  Id — and writes the complete expected order in ONE Set-VMFirmware. Spike 0.4 measured
  why the obvious shapes fail: a subset write silently deleted the lab VM's own hard
  drive from its boot order, and a retry that re-inserts a device already present
  duplicates it. So the script classifies entries by the Device rendering first and
  BootType only as the fallback (the PR-1 lab measurement caught the first version
  of this rule inverted: a NIC entry answers BootType 'Network', so BootType-first
  never matched a requested VMNetworkAdapter, the fetch branch added the same adapter
  a second time, and the host refused the duplicate; a File entry is the case that
  needs the fallback, its Device being null), matches a
  requested drive by comparing its Id against each entry's Device.Id rather than by
  object reference (a freshly fetched device object never reference-equals a boot entry's
  Device), appends every entry it did not consume, and — if the read-back order is not
  what it wrote — restores the captured original and raises rather than leaving the VM
  half-reordered. Unknown or repeated classes, an empty order, and a non-DVD class named
  by Id refuse before any traffic.

- Answer the DVD-drive requests under Fog.mock!, so a plugin can drive one drive
  through add, attach, read, eject and remove without a Hyper-V host: get_vm_dvd_drive's
  Mock read a local named args that the method never defines (it takes **options), which
  raised NameError on every mocked DVD read before it looked at the fixture beside it,
  and it filtered only by vm_id so a drive named by Id was answered by whichever drive
  the VM had. Add/Set/Remove had no Mock at all and fell through to method_missing,
  which raises MockNotImplemented because a passthru cmdlet has no fixture of its own;
  they now answer from get_vm_dvd_drive's fixture rather than growing three
  near-identical JSON files, with Set answering the drive as it was BEFORE the
  change — the shape the lab measured Set-VMDvdDrive -Passthru to answer on a
  real Gen2 cluster VM (an eject's answer carried the file the eject had just
  released while the next fresh read already answered it gone) — so
  DvdDrive#update never merges that answer: the model re-reads the drive after
  the write (a merge-back left it holding the pre-change state and diffing
  against it, which made a following eject see no change and send no request at
  all), so what the model carries is the host's fresh answer.

- Delete one file inside a directory the caller names, and answer whether there
  was anything to delete: remove_file takes `root` as a required argument and
  refuses, before any wire traffic, every path that is not that directory or one
  literal location inside it (relative or drive-relative, wildcarded, carrying
  `/` as a separator, carrying `..`, or outside its root), then tests for the
  file and deletes it in the SAME script. Absence answers false instead of
  raising PSError the way remove_item does on a repeated cleanup — measured on
  the lab node, where Remove-Item of a missing path raised even under
  -ErrorAction SilentlyContinue — which is what a caller that cleans up the same
  path twice needs. A folder is refused rather than deleted, and an answer the
  script could not have printed raises RemovalVerdictUninterpretable instead of
  being read as "nothing to do". CAPABILITIES gains contained_file_removal.

- Carry the cluster's preferred owners into the clustered-role read:
  build_read_script now asks Get-ClusterOwnerNode of every matched group and
  rows come back with preferredNodeNames, mirrored by the model's
  preferred_node_names — the measured source for this state on HV-CL01
  (evidence section 76), because the group object's own PreferredNodeNames
  property is NULL and the unfiltered cmdlet answers nothing at all. The
  three arrived states stay distinct: a list of names is a restricted
  preference, [] is the cluster's own positive "no restricted list — any
  node may own" answer, and nil means that group's owner read failed, which
  is not "no restriction". CAPABILITIES gains cluster_role_owner_nodes;
  the build's Set-ClusterOwnerNode -Owners write surface is measured but
  not exposed in this release
- Recognise hyperv_operation_timeout, hyperv_receive_timeout,
  hyperv_retry_limit and hyperv_retry_delay and pass them to the WinRM
  connection: the gem's waits describe a local network, and a high-latency or
  lossy path could not say otherwise without patching the gem. Unset keeps the
  gem's own numbers, and a value that is not a number says which option was
  wrong
- Ask a newly connected host its short name and its fully qualified one in one
  shell call rather than two: each was a command and a receive on the wire, and
  both read the same $env:computerName, so every first contact with an endpoint
  cost a round trip it did not need
- Let a host that will not answer for its own names keep the connection:
  GetHostByName throws on a machine whose name does not resolve and the shell's
  Stop preference turns that into a raised error, which aborted a connect that
  had already registered the endpoint under the name it was made to. The
  discovery now says so in the debug log and the connection loses the extra
  names and nothing else
- Run the shell settings as part of the first command instead of as a call of
  their own: every shell.run is a command and a receive on the wire, so the
  separate settings call was a full round trip paid before every single thing
  asked of a host
- Send the Kerberos connection its service principal: the gem builds it as
  "<service>/<host>@<realm>", refuses a kerberos connection that names none,
  and fog named none — a realm, which is all the Kerberos option has ever
  carried, could therefore never authenticate. WinRM listeners answer to
  WSMAN, which is what is sent now; hyperv_service overrides it for a listener
  published under another principal
- Recognise hyperv_ssl_verify, hyperv_ca_trust_path, hyperv_client_cert,
  hyperv_client_key and hyperv_key_pass, and give hyperv_transport the
  transport that authenticates by certificate to speak
- Verify the TLS peer of an https endpoint by default, which the connection
  used to switch off unconditionally. This changes behaviour for an https
  endpoint with a certificate the trust store does not answer for: it fails
  instead of connecting, and wants hyperv_ca_trust_path pointing at the CA
  that issued it or hyperv_ssl_verify: false to say otherwise. Encryption
  that never says who is at the other end is not protection on a routed path
- Take an Integer 0 for hyperv_ssl_verify as the opt-out it spells: YAML reads
  an unquoted 0 as the Integer rather than the string, and Ruby counts the
  Integer as truthy, so a file that said hyperv_ssl_verify: 0 was verifying
  while saying otherwise
- Default the transport to kerberos when a realm is given and to ssl when a
  client certificate is given, before falling back to negotiate: ruby-winrm's
  negotiate always wraps NTLM tokens and NTLM is deprecated by its vendor
  with disabling it the stated end state, so the transports that do not speak
  it should not need to be asked for by name
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
- Read and write the one high-availability setting a clustered virtual machine
  actually takes: the role read now carries auto_failback (and the failback
  window, with the measured 4294967295 sentinel read as "no window"), and
  set_cluster_virtual_machine_role_auto_failback writes automatic failback
  through a shell that identifies the group before touching it and proves the
  write with a fresh read-back — a cluster that answers "Unable to save
  property changes" now raises RolePropertyWriteRefused carrying its own words
  instead of the setting being reported as applied, and an unclustered machine
  answers ClusterRoleNotFound. Priority and the window refuse as writes on the
  measured build, so they stay read fields
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
