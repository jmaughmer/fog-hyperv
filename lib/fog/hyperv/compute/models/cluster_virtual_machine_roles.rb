# frozen_string_literal: true

class Fog::Hyperv::Compute
  # The clustered virtual machine roles of the cluster the compute resource's endpoint
  # belongs to.
  class ClusterVirtualMachineRoles < Fog::Hyperv::Collection
    model Fog::Hyperv::Compute::ClusterVirtualMachineRole

    get_method :get_cluster_virtual_machine_role

    # Asks for one role, by either of the two things that identify one.
    #
    # The name form is kept because it is the original contract of this collection
    # and reads well at a call site. The keyword form is the one that matters to a
    # machine: a caller holding a Server has its GUID and nothing else, and the
    # role group's real name is the machine's name as the cluster knows it — not
    # something this side can construct, since it has no local name source and a
    # rename changes it silently.
    #
    # Asking for no role at all is refused rather than answered. With no filter the
    # request would read every role on the cluster, and handing back the first of
    # those would be a role belonging to some other machine — which is the one
    # mistake a lookup like this cannot afford to make.
    def get(name = nil, **filters)
      filters = filters.merge(name: name) unless name.nil?
      if filters.empty?
        raise ArgumentError,
              'cluster_virtual_machine_roles.get needs a role name or a vm_id: with neither it ' \
              'would read every role on the cluster and return somebody else’s'
      end

      super(**filters)
    end
  end
end
