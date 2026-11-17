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

