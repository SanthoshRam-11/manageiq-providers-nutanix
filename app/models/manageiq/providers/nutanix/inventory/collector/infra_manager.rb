class ManageIQ::Providers::Nutanix::Inventory::Collector::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Collector
  def clusters
    @clusters ||= begin
      clusters_api = NutanixClustermgmt::ClustersApi.new(cluster_mgmt_connection)
      clusters_api.list_clusters.data
    end
  end

  def hosts
    @hosts ||= begin
      clusters_api = NutanixClustermgmt::ClustersApi.new(cluster_mgmt_connection)
      clusters_api.list_hosts.data
    end
  end

  def datastores
    @datastores ||= begin
      volume_api = NutanixClustermgmt::StorageContainersApi.new(cluster_mgmt_connection)
      volume_api.list_storage_containers.data
    end
  end

  def templates
    @templates ||= begin
      template_api = NutanixVmm::TemplatesApi.new(vmm_connection)
      template_api.list_templates.data
    end
  end

  def vms
    @vms ||= begin
      vms_api = NutanixVmm::VmApi.new(vmm_connection)
      vms_summary = vms_api.list_vms_0.data

      # Fetch full details per VM (one by one)
      vms_summary.map do |summary|
        uuid = summary.ext_id || summary.uuid || summary.id
        vms_api.get_vm_by_id_0(uuid).data  # this returns a full NutanixVmm::VmmV40AhvConfigVm
      end
    end
  end
end