# Fog Hyper-V

[![Gem Version](https://badge.fury.io/rb/fog-hyperv.svg)](https://badge.fury.io/rb/fog-hyperv)

Manage your Hyper-V instance with the help of the Fog cloud service abstractions.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fog-hyperv'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fog-hyperv

## Usage

To remotely manage your Hyper-V instance;

```ruby
require 'fog/hyperv'

compute = Fog::Compute.new(
  provider: :hyperv,
  hyperv_host: 'hyperv.example.com',
  hyperv_username: 'domain\\user',
  hyperv_password: 'password'
)

compute.servers.all
#=> [<Fog::Compute::Hyperv::Server
#=>   id='',
#=>   name='example',
#=>   computer_name='HYPERV',
#=>   dynamic_memory_enabled=false,
#=>   ...
```

## Authentication and encryption

The default transport, `negotiate`, is not what it sounds like: ruby-winrm wraps
NTLM tokens in the Negotiate scheme and never attempts a Kerberos leg, so every
connection is NTLM whatever the server would prefer. NTLM is deprecated by its
vendor — Microsoft has removed NTLMv1, plans to block NTLM single-sign-on by
default from late 2026, and has stated that disabling NTLM outright is the end
state — so a deployment should treat NTLM as what's left when the transports
below cannot be had, not as the default.

* `hyperv_realm: 'EXAMPLE.COM'` authenticates over Kerberos (transport
  `kerberos`, password-based GSSAPI; the calling machine needs working MIT
  Kerberos). Kerberos authenticates the server back to the client, which NTLM
  never does, and costs one round-trip where the NTLM handshake costs several —
  worth real seconds per connection on a high-latency link.
* `hyperv_client_cert:`/`hyperv_client_key:` (with `hyperv_key_pass:` for an
  encrypted key) authenticate by certificate over `https`, for listeners set up
  with `Negotiate`/`Client` certificate authentication. This is the NTLM-free
  option for a workgroup host with no domain to Kerberos against.
* `hyperv_transport:` overrides the choice: `'negotiate'`, `'kerberos'` or
  `'ssl'`. A realm on its own means `kerberos`, a client certificate on its own
  means `ssl`, both means `kerberos`.

An `https` endpoint is verified against the system trust store by default.
`hyperv_ca_trust_path:` points at the CA certificate (or store directory) when
it is not there, and `hyperv_ssl_verify: false` turns verification off for a
self-signed listener — worth knowing that an unverified `https` endpoint
encrypts the conversation without ever saying who is at the other end, which
over any routed path is encryption that buys nothing; the WinRM service's own
certificate management (AD CS auto-enrolment, `winrm quickconfig` over HTTPS)
or `ca_trust_path` are the answers to why you might want it off.

```ruby
compute = Fog::Compute.new(
  provider: :hyperv,
  hyperv_endpoint: 'https://hyperv.example.com:5986/wsman',
  hyperv_username: 'foreman@EXAMPLE.COM',
  hyperv_password: 'password',
  hyperv_realm: 'EXAMPLE.COM',
  hyperv_ca_trust_path: '/etc/pki/hyperv/listener-ca.pem'
)
```

## Timeouts and retries

WinRM is a conversation on the wire twice over: opening a shell waits on a
reply, and a running command is collected in long-poll receives that hold the
connection until the command answers. The winrm gem's waits describe a local
network — 60 seconds to an operation, 70 to a receive, three shell-open retries
ten seconds apart — and a path with hundreds of milliseconds of latency and
real loss on it can exceed those legitimately. `hyperv_operation_timeout` and
`hyperv_receive_timeout` (seconds) set the waits, `hyperv_retry_limit` and
`hyperv_retry_delay` the retries of a shell that would not open; leaving one
out keeps the gem's number. The gem raises if a receive timeout is given below
its operation timeout rather than silently truncating commands.

A satellite site worth naming: on an 800 ms link a single fog call is six or
seven round trips deep — shell open, command, receives, cleanup — so retries
of ten seconds are better asked about than inherited, and the transports that
skip the NTLM handshake (above) save their own two or three seconds per
connection on such a path.

## Failover clusters

A cluster is managed through its nodes, so **point `hyperv_endpoint`/`hyperv_host` at
a node, never at the cluster's own name**. The cluster name resolves to a Client
Access Point — a network name that moves between nodes — and WinRM, the Failover
Clustering cmdlets and `Get-VMHost` all live on a real machine. Asking the cluster
name is how a working configuration fails with a WinRM error nobody can explain.

* Every request carries the machine it should run on (`target_computer`), and nodes
  other than the configured one are reached at the configured endpoint's scheme, port
  and path — a cluster running WinRM over HTTPS on 5986 is reachable, one on a
  different path is not.
* The account has to be a **cluster** administrator, which in practice means a domain
  account in the local *Administrators* group of every node. A local account cannot be
  a cluster administrator, so it manages the node it lives on and nothing above it.
* `supports_clusters?` is the cheap gate: one WMI query against `root/mscluster`,
  false when the Failover Clustering module is absent (client SKUs, and any server
  without the RSAT tools) rather than an error. `Get-VMHostCluster` is deliberately
  not used: it goes to Active Directory for cluster *computer objects*, which is both
  the wrong question and, on a network with unreachable domain controllers, a stall of
  minutes rather than seconds.
* Ask a node about its own cluster: the read requests take `id: nil` and run
  `Get-Cluster` piped into the cmdlet, so any node answers for the cluster it belongs
  to. `Cluster#nodes` reports state and votes without needing WinRM on the node it is
  describing; `Cluster#hosts` follows with each node's `Get-VMHost`, which does.
* A machine's `computer_name` goes stale the moment its role moves. A `Server` reads
  `clustered?`, `cluster_role` and `owner_node`; a caller holding only the VM's GUID
  finds the role with `client.cluster_virtual_machine_roles.all(vm_id: uuid)` and then
  asks that node. fog's own `Server#reload` still reads `computer_name`.
* A clustered machine's config and disks have to live where every node can reach them:
  `Cluster#shared_volumes` lists the cluster shared volumes, and `Server#create`'s
  `path:` takes one of those paths. `Add-ClusterVirtualMachineRole` refuses a machine
  whose storage is on a local path.

Two honesty notes about the cluster surface. Enum-valued properties (`State`,
`Priority`, quorum type) come back as the raw integers the cmdlet answers with — the
names are not mapped, because a wrong mapping is worse than a number. And the mocked
cluster fixtures other than `get_cluster.json`/`get_cluster_node.json` were written
from cmdlet documentation, not captured from a real cluster: see
`lib/fog/hyperv/compute/requests/mock_files/README.md` for which is which.

## Troubleshooting

If you're getting `WinRM::AuthorizationErrors` from the negotiate transport
even when using a valid user, make sure that the WinRM service is configured
for Negotiate auth.

If you're using a local (non-domain) user, you may also need to set the DWORD
registry value `LocalAccountTokenFilterPolicy` at `HKLM\software\Microsoft\Windows\CurrentVersion\Policies\system`
to `1`.

A service account that is only a member of *Hyper-V Administrators* will
authenticate and read WMI fine, then fail every cmdlet with `You do not have
the required permission to complete this task. Contact the administrator of the
authorization policy for the computer 'HOST'`. A WinRM logon is a network logon
and its token is not elevated, and the Hyper-V authorization check rejects such
a token unless it also carries *BUILTIN\Administrators*. Add the account to the
local *Administrators* group as well; with `LocalAccountTokenFilterPolicy=1`
set, remote tokens for local administrator accounts do keep that group enabled
instead of filtering it out.

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `rake test` to run the tests. You can also run `bundle exec irb` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on the LiU GitLab at https://gitlab.liu.se/ITI/fog-hyperv or GitHub at https://github.com/ananace/fog-hyperv

