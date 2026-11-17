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
