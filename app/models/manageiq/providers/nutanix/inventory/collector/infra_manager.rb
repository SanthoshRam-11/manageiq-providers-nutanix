class ManageIQ::Providers::Nutanix::Inventory::Collector::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Collector
  def connection
    port = manager.port || 9440
    @connection ||= ManageIQ::Providers::Nutanix::InfraManager.raw_connect(
      manager.hostname,
      port,
      manager.authentication_userid,
      manager.authentication_password,
      manager.verify_ssl || OpenSSL::SSL::VERIFY_NONE
    )
  end

  def clusters
    @clusters ||= {}
    
   # Collect clusters from VM references only
    vms.each do |vm|
      next unless vm.cluster
      
      @clusters[vm.cluster.ext_id] ||= {
        :name => "Cluster-#{vm.cluster.ext_id}",  # Default name pattern
        :ems_ref => vm.cluster.ext_id
      }
    end
    
    @clusters
  end

  def hosts
   @hosts ||= {}
    
   # Collect hosts from VM references
    vms.each do |vm|
      next unless vm.host
      
      @hosts[vm.host.ext_id] ||= {
        :name => "Host-#{vm.host.ext_id}",  # Default name pattern
        :ems_ref => vm.host.ext_id
      }
    end
    
    @hosts
  end

  def volume_connection
    @volume_connection ||= begin
      config = NutanixVolumes::Configuration.new.tap do |c|
        c.scheme = "https"
        c.host = "#{manager.hostname}:#{manager.port || 9440}"
        c.username = manager.authentication_userid
        c.password = manager.authentication_password
        c.verify_ssl = false
        c.verify_ssl_host = false
      end

      NutanixVolumes::ApiClient.new(config).tap do |client|
        client.default_headers['Accept-Encoding'] = 'identity'
      end
    end
  end


  def datastores
    @datastores ||= begin
      volume_api = NutanixVolumes::VolumeGroupsApi.new(volume_connection)
      response = volume_api.list_volume_groups
      response.data
    rescue => e
      $log.error("Error collecting datastores: #{e.message}")
      []
    end
  end

  def templates
    @templates ||= begin
      template_api = NutanixVmm::TemplatesApi.new(connection)
      response = template_api.list_templates
      response.data  # <-- extract the array of templates here
    end
  end


  def vms
    @vms ||= begin
      api_client = manager.connect
      vms_api = NutanixVmm::VmApi.new(api_client)
      vms_api.list_vms_0.data
    end
  end
end
