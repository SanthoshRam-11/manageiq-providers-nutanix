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
      vms_api.list_vms_0.data
    end
  end
end
