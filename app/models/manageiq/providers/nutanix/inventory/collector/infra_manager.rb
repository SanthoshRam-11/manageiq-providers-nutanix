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

  Datastore = Struct.new(:container_ext_id, :name, :max_capacity_bytes, :clusterName, :cluster_uuid, :stats)

def datastores
  @datastores ||= begin
    storage_api = NutanixClustermgmt::StorageContainersApi.new(cluster_mgmt_connection)
    configs = storage_api.list_storage_containers.data

    # Create cluster name to UUID mapping
    cluster_map = {}
    clusters.each do |cluster|
      cluster_map[cluster.name] = cluster.ext_id
    end

    end_time = Time.now.utc.iso8601
    start_time = (Time.now.utc - 3600).iso8601  # 1 hour ago

    configs.map do |config|
      stats = storage_api.get_storage_container_stats(
        config.container_ext_id,
        start_time,
        end_time
      ).data

      # Get cluster UUID using cluster name
      cluster_uuid = cluster_map[config.cluster_name]

      Datastore.new(
        config.container_ext_id,
        config.name,
        config.max_capacity_bytes,
        config.cluster_name,
        cluster_uuid,  # Use mapped UUID
        stats
      )
    end
  rescue => e
    $log.error("Error collecting datastores: #{e.message}")
    []
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