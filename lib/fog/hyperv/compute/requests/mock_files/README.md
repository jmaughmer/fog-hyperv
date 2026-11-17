# Mock fixtures

Each `mock_files/<request>.json` is the JSON a request's PowerShell would have
written: `Fog::Hyperv::Compute::Mock#handle_mock_response` reads it, uncamelizes the
keys and, when the caller asked for specific fields, slices the objects down to
them. So the shapes here are what the cmdlets answer, not what a model wants.

Two kinds of fixture live here, and the difference matters while the failover
cluster work is in progress:

* **captured** — taken from a real Hyper-V host (`JM-WORKSTATION`, Windows 11
  build 26300) through the same `ConvertTo-Json` the real requests emit, then
  trimmed. `get_vm_host.json`, `get_vm.json`, `get_switch.json` and the rest of the
  single-host set are this kind.
* **captured, and old** — `get_cluster.json` and `get_cluster_node.json` came with
  the gem and carry a real cluster's shape (`BuildNumber` 9600, so Windows Server
  2012 R2), but a one-node one. The second node added to `get_cluster_node.json`,
  and everything below, is not.
* **provisional — re-capture in the lab** — written from Microsoft's documented
  output because no cluster has been reachable while these were written:
  `get_cluster_shared_volume.json`, `get_cluster_virtual_machine_role.json`,
  `get_cluster_network.json`, `get_cluster_quorum.json`,
  `get_cluster_available_disk.json`, `get_vm_high_availability.json`, and the
  `mock-node2` entry in `get_cluster_node.json` with the `MOCK-NODE2` entry in
  `get_vm_host.json` that lets `Cluster#hosts` resolve it.

The provisional set describes one two-node cluster — `mock-cluster` on nodes
`mock-host` and `mock-node2`, with shared volumes `Volume1` and `Volume2` under
`C:\ClusterStorage` — and `get_vm_host.json` carries a matching `MOCK-NODE2` so
`Cluster#hosts` resolves both nodes the way it will resolve real ones. Property
names follow the cmdlet documentation; the values are invented. Re-capture every one
of them against the cluster lab and keep the names, or the unit tests will keep
passing on a shape a real cluster never produces.

Nothing in the fixtures is secret; `example.com` and the GUIDs are made up.
