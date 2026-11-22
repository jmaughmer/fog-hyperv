# frozen_string_literal: true

class Fog::Hyperv::Compute
  # A cluster known to Hyper-V
  #
  # This model is read-only and strictly informative
  class Cluster < Fog::Hyperv::Model
    # @!attribute [r] id
    #   @return [String] the GUID of the cluster
    identity :id, type: :string

    # @!attribute [r] description
    #   @return [String] the description of the cluster
    attribute :description, type: :string
    # @!attribute [r] domain
    #   @return [String] the domain of the cluster
    attribute :domain, type: :string
    # @!attribute [r] name
    #   @return [String] the name of the cluster
    attribute :name, type: :string

    # @!attribute [r] hosts
    #   @return [Array<Host>] the cluster's nodes as Hyper-V describes them — paths,
    #     memory, switches, machines. Heavier than #nodes: this opens a WinRM shell on
    #     every node, and a node that answers Get-ClusterNode but not WinRM takes the
    #     whole listing down with it, which a caller that wants to report a down node
    #     should go through #nodes for instead.
    def hosts
      return [] unless persisted?

      cluster_nodes.map { |n| service.hosts.get(n[:name]) }
    end

    # @!attribute [r] roles
    #   @return [Array<ClusterVirtualMachineRole>] the virtual machines this cluster
    #     runs as clustered roles, each with the node that owns it. A machine on a
    #     clustered host that is not in this list runs on one node and nothing more:
    #     it is manageable, it is just not highly available.
    def roles
      return [] unless persisted?

      # No filter is passed: the cmdlet has no cluster-id filter to apply, and the
      # endpoint answers for the cluster it belongs to — which the read names in
      # its answer rather than taking it on trust here. Passing this model's id as
      # a filter would claim a filter that does not exist.
      service.cluster_virtual_machine_roles.all
    end

    # @!attribute [r] nodes
    #   @return [Array<ClusterNode>] the cluster's nodes as the cluster sees them,
    #     which includes the ones that are down and so answer nothing to Get-VMHost.
    #     Cheap next to #hosts, which opens a WinRM shell per node.
    def nodes
      return [] unless persisted?

      requires :id
      service.cluster_nodes.all(id: id)
    end

    # @!attribute [r] networks
    #   @return [Array<ClusterNetwork>] the cluster's own networks: heartbeats, live
    #     migration and the address clients reach the cluster through. Not the
    #     switches a virtual machine connects to, which are Host#switches.
    def networks
      return [] unless persisted?

      requires :id
      service.cluster_networks.all(id: id)
    end

    # @!attribute [r] quorum
    #   @return [Hash] how the cluster votes — its quorum type and the witness behind
    #     it, as the cmdlet answers. A hash rather than a model because a cluster has
    #     exactly one quorum and nothing about it is addressable.
    def quorum
      return {} unless persisted?

      requires :id
      [service.get_cluster_quorum(id: id)].flatten.compact.first.to_h
    end

    # @!attribute [r] shared_volumes
    #   @return [Array<ClusterSharedVolume>] the Cluster Shared Volumes of this
    #     cluster, which is where the disks of its virtual machines have to live.
    #     Nothing to ask here on a stand-alone host: no cluster, no CSVs.
    def shared_volumes
      return [] unless persisted?

      requires :id
      service.cluster_shared_volumes.all(id: id)
    end

    # @!attribute [r] available_disks
    #   @return [Array<Hash>] the disks the cluster can see that no cluster role owns
    #     yet, the pool a new shared volume would be built from. Plain hashes rather
    #     than models: a free disk has no identity anyone acts on, only a number, a
    #     size and a path, and it stops being one the moment it is added to the
    #     cluster.
    def available_disks
      return [] unless persisted?

      requires :id
      [service.get_cluster_available_disk(id: id)].flatten.compact
    end

    # Reload the cluster information from Hyper-V
    def reload
      requires :id

      # Get-Cluster answers with a single object when one cluster matches and an
      # array when more than one does, and the mock fixture is an array either way,
      # so all three shapes have to be accepted. The entries are plain Hashes:
      # unlike some other requests there is no model behind this one to ask for
      # attributes off, which is what reading data.attributes used to do.
      data = [service.get_cluster(id: id, _return_fields: self.class.attributes)].flatten.compact
      data = data.find { |cluster| cluster[:id] == id } || data.first
      return unless data

      merge_attributes(data)
    end

    private

    def cluster_nodes
      return [] unless persisted?

      requires :id

      [service.get_cluster_node(id: id, _return_fields: %i[name])].flatten
    end
  end
end
