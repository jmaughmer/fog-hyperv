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
    #   @return [Array<Host>] the list of hosts in the cluster
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

      requires :id
      service.cluster_virtual_machine_roles.all(id: id)
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
