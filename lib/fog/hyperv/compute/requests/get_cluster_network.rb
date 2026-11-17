# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    # The cluster's networks: which of the nodes' networks carry cluster traffic,
    # which carry client access to the cluster's address, and in what order they are
    # preferred. Informative for now — a virtual machine's switch is chosen from
    # Get-VMSwitch, not from here — but a validation report wants to say when a node
    # has no cluster network at all.
    def get_cluster_network(id: nil, **options)
      run_cmdlist(
        [
          ['$Cluster = Get-Cluster', { _by_id: id }],
          ['$Cluster | Get-ClusterNetwork', options]
        ]
      )
    end
  end

  class Mock
    def get_cluster_network(**args)
      data = handle_mock_response(**args)
      data = data.select { |network| network[:name].casecmp(args[:name].to_s).zero? } if args[:name]
      data
    end
  end
end
