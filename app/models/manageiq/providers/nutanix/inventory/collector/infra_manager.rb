class ManageIQ::Providers::Nutanix::Inventory::Collector::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Collector
  require 'rest-client'
  require 'json'
  require 'openssl'
  Datastore = Struct.new(:container_ext_id, :name, :max_capacity_bytes, :cluster_name, :cluster_uuid, :stats)

  def clusters
    @clusters ||= begin
      clusters_api = NutanixClustermgmt::ClustersApi.new(cluster_mgmt_connection)
      clusters_api.list_clusters.data
    end
  end

  def hosts
    @hosts ||= begin
      hosts_api = NutanixClustermgmt::ClustersApi.new(cluster_mgmt_connection)
      hosts_api.list_hosts.data
    end
  end

  def datastores
    @datastores ||= begin
      storage_api = NutanixClustermgmt::StorageContainersApi.new(cluster_mgmt_connection)
      configs = storage_api.list_storage_containers.data

      # Map cluster name to UUID
      cluster_map = clusters.to_h { |cluster| [cluster.name, cluster.ext_id] }

      end_time = Time.now.utc.iso8601
      start_time = (Time.now.utc - 3600).iso8601

      configs.map do |config|
        stats = storage_api.get_storage_container_stats(
          config.container_ext_id,
          start_time,
          end_time
        ).data

        cluster_uuid = cluster_map[config.cluster_name] || "unknown"

        Datastore.new(
          config.container_ext_id,
          config.name,
          config.max_capacity_bytes,
          config.cluster_name,
          cluster_uuid,
          stats
        )
      end
    rescue => e
      $log.error("Error collecting datastores: #{e.message}")
      []
    end
  end

  def container_stats_by_id
    @container_stats_by_id ||= datastores.index_by(&:container_ext_id)
  end

  def templates
    @templates ||= begin
      template_api = NutanixVmm::TemplatesApi.new(vmm_connection)
      template_api.list_templates.data
    end
  end

  def fetch_raw_vm_by_id(vm_ext_id)
    puts "DEBUG: Collector manager hostname = #{manager.hostname}"
    url = "https://#{manager.hostname}:9440/api/vmm/v4.0/ahv/config/vms/#{vm_ext_id}"
    puts "DEBUG: Fetching full raw VM JSON from URL: #{url}"
    response = RestClient::Request.execute(
      method: :get,
      url: url,
      user: manager.authentication_userid,
      password: manager.authentication_password,
      verify_ssl: false
    )
    json = JSON.parse(response.body)
    json["data"]
  rescue => e
    $log.warn("Failed to fetch raw VM #{vm_ext_id}: #{e.message}")
    nil
  end

  def list_vm_ids
    url = "https://#{manager.hostname}:9440/api/vmm/v4.0/ahv/config/vms"
    response = RestClient::Request.execute(
      method: :get,
      url: url,
      user: manager.authentication_userid,
      password: manager.authentication_password,
      verify_ssl: false
    )
    parsed = JSON.parse(response.body)                     # ✅ assign first
    puts "DEBUG: VM list response: #{parsed.inspect}"      # ✅ log after
    parsed["data"] || []
  rescue => e
    $log.warn("Failed to fetch VM list: #{e.message}")
    []
  end

  def vms
    @vms ||= list_vm_ids
  end

  def disk_by_id(vm_ext_id, disk_ext_id)
    # Use the existing fetch_disk_json method
    json = fetch_disk_json(vm_ext_id, disk_ext_id)
    return nil unless json
    json.dig('data') # Extract the 'data' part from the response
  end

  def fetch_disk_json(vm_ext_id, disk_ext_id)
    url = "https://#{@ems.hostname}:9440/api/vmm/v4.0/ahv/config/vms/#{vm_ext_id}/disks/#{disk_ext_id}"
    puts "DEBUG: Fetching disk JSON from URL: #{url}"
    response = RestClient::Request.execute(
      method: :get,
      url: url,
      user: @ems.authentication_userid,
      password: @ems.authentication_password,
      verify_ssl: false
    )
    JSON.parse(response.body)
  rescue => e
    $log.warn("Failed to fetch disk #{disk_ext_id} for VM #{vm_ext_id}: #{e.message}")
    nil
  end

  def subnets_by_ref
    @subnets_by_ref ||= begin
      subnets = []  # Replace with actual REST call
      subnets.compact.index_by { |s| s.respond_to?(:ext_id) ? s.ext_id : nil }
    end
  end

  def list_subnets
    @subnets ||= begin
      url = "https://#{@ems.hostname}:9440/api/networking/v4.0.a1/config/subnets"
      response = RestClient::Request.execute(
        method: :get,
        url: url,
        user: @ems.authentication_userid,
        password: @ems.authentication_password,
        verify_ssl: false
      )
      json = JSON.parse(response.body)
      json["entities"] || []
    rescue => e
      $log.warn("Failed to fetch subnet list: #{e.message}")
      []
    end
  end

  # Hash map for fast lookup by UUID
  def subnets_by_id
    @subnets_by_id ||= list_subnets.index_by { |s| s.dig("metadata", "uuid") }
  end

  # Optional: fetch a **single** subnet by UUID (if needed in detail)
  def fetch_subnet_by_id(subnet_uuid)
    url = "https://#{@ems.hostname}:9440/api/networking/v4.0.a1/config/subnets/#{subnet_uuid}"
    response = RestClient::Request.execute(
      method: :get,
      url: url,
      user: @ems.authentication_userid,
      password: @ems.authentication_password,
      verify_ssl: false
    )
    JSON.parse(response.body)
  rescue => e
    $log.warn("Failed to fetch subnet #{subnet_uuid}: #{e.message}")
    nil
  end

end
