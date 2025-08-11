class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser
  def parse
    puts "DEBUG: In parser#parse, total VMs = #{collector.vms.count}"
    @cluster_hosts = Hash.new { |h, k| h[k] = [] }
    parse_hosts
    parse_clusters
    parse_templates
    parse_subnets
    collector.vms.each do |vm|
      puts "DEBUG: Parsing VM #{vm['name']} (#{vm['extId']})"
      parse_vm(vm)
    end
    parse_datastores
    parse_host_storages
  end

  private

  def parse_clusters
    collector.clusters.each do |cluster|
      persister.clusters.build(
        :ems_ref => cluster.ext_id,
        :name    => cluster.name,
        :uid_ems => cluster.ext_id
      )
    end
  end

  def parse_hosts
    collector.hosts.each do |host|
      cluster_uuid = host.cluster&.uuid
      ems_cluster = persister.clusters.lazy_find(host.cluster.uuid) if host.cluster&.uuid

      @cluster_hosts[cluster_uuid] << host.ext_id if cluster_uuid
      # In parse_hosts_and_clusters method
      persister_host = persister.hosts.build(
        :ems_ref     => host.ext_id,
        :name        => host.host_name,
        :ems_cluster => ems_cluster
      )

      memory_mb = host.memory_size_bytes / 1.megabyte if host.memory_size_bytes
      persister.host_hardwares.build(
        :host            => persister_host,
        :memory_mb       => memory_mb,
        :cpu_sockets     => host.number_of_cpu_sockets,
        :cpu_total_cores => host.number_of_cpu_cores
      )
    end
  end

  def parse_vm(vm)
    puts "DEBUG: Parsing VM #{vm['name']} (#{vm['extId']})"

    os_info = vm['description'].to_s.match(/OS: (.+)/)&.captures&.first || 'unknown'

    vm_obj = persister.vms.build(
      :ems_ref          => vm['extId'],
      :uid_ems          => vm['biosUuid'],
      :name             => vm['name'],
      :description      => vm['description'],
      :location         => vm.dig('cluster', 'extId') || "unknown",
      :vendor           => "nutanix",
      :raw_power_state  => vm['powerState'],
      :host             => persister.hosts.lazy_find(vm.dig('host', 'extId')),
      :ems_cluster      => persister.clusters.lazy_find(vm.dig('cluster', 'extId')),
      :ems_id           => persister.manager.id,
      :connection_state => "connected",
      :boot_time        => vm['createTime']
    )

    hardware = persister.hardwares.build(
      :vm_or_template       => vm_obj,
      :memory_mb            => (vm['memorySizeBytes'] || 0) / 1.megabyte,
      :cpu_total_cores      => vm['numSockets'].to_i * vm['numCoresPerSocket'].to_i,
      :cpu_sockets          => vm['numSockets'],
      :cpu_cores_per_socket => vm['numCoresPerSocket'],
      :guest_os             => os_info
    )

    parse_disks(vm, hardware)
    parse_vm_nics(vm, hardware)
    parse_operating_system(vm, hardware, os_info, vm_obj)
  end


  def parse_disks(vm, hardware)
    # Regular disks
    disks = vm['disks'] || []

    disks.each_with_index do |disk, i|
      disk_ext_id   = disk['extId']
      size_bytes    = disk.dig('backingInfo', 'diskSizeBytes') || 0
      storage_ref   = disk.dig('backingInfo', 'storageContainer', 'extId')
      bus_type      = disk.dig('diskAddress', 'busType') || "unknown"
      controller    = disk.dig('backingInfo', 'deviceBus') || bus_type || "scsi"
      index         = disk.dig('diskAddress', 'index') || 0
      is_bootable   = disk.dig('deviceProperties', 'isBootable') || index.to_i == 0

      persister.disks.build(
        :hardware        => hardware,
        :device_name     => "Disk #{i}",
        :device_type     => bus_type,
        :controller_type => controller,
        :size            => size_bytes,
        :location        => index.to_s,
        :filename        => disk_ext_id,
        :bootable        => is_bootable,
        :storage         => persister.storages.lazy_find(storage_ref)
      )
    end

    # CD-ROM disks
    (vm['cdRoms'] || []).each_with_index do |cdrom, i|
      backing_info = cdrom['backingInfo'] || {}
      disk_ext_id  = cdrom['extId']
      controller   = backing_info['deviceBus'] || "ide"

      persister.disks.build(
        :hardware        => hardware,
        :device_name     => "CD-ROM #{i}",
        :device_type     => "cdrom",
        :controller_type => controller,
        :size            => backing_info['diskSizeBytes'] || 0,
        :location        => i.to_s,
        :filename        => disk_ext_id,
        :storage         => persister.storages.lazy_find(backing_info.dig('storageContainer', 'extId'))
      )
    end
  end

  def global_subnet_catalog
    @global_subnet_catalog ||= collector.subnets_by_id.transform_values do |subnet|
      {
        :network_name => subnet["name"],
        :vlan_id      => subnet["networkId"],
        :gateway      => subnet.dig("ipConfig", 0, "ipv4", "defaultGatewayIp", "value"),
        :dhcp_ip      => subnet.dig("ipConfig", 0, "ipv4", "dhcpServerAddress", "value"),
        :ip_range     => subnet.dig("ipConfig", 0, "ipv4", "poolList")&.map do |p|
                          "#{p.dig("startIp", "value")} - #{p.dig("endIp", "value")}"
                        end || [],
        :sample_ip    => subnet.dig("ipConfig", 0, "ipv4", "poolList", 0, "startIp", "value") ||
                        subnet.dig("ipConfig", 0, "ipv4", "ipSubnet", "ip", "value")
      }
    end
  end

  def parse_vm_nics(vm, hardware)
    nics = vm['nics'] || []
    if nics.empty?
      puts "WARN: VM #{vm['name']} has no NICs"
      return
    end

    nics.each_with_index do |nic, index|
      subnet_id   = nic.dig('networkInfo', 'subnetReference', 'uuid')
      ip_address  = nic.dig('networkInfo', 'ipv4Config', 'ipAddress', 'value')
      mac_address = nic.dig('backingInfo', 'macAddress') || "unknown"
      nic_ext_id  = nic['extId']
      subnet      = global_subnet_catalog[subnet_id]

      puts "DEBUG: VM #{vm['name']} NIC #{index}: extId=#{nic_ext_id}, subnet_id=#{subnet_id}, IP=#{ip_address}, MAC=#{mac_address}"

      if subnet_id.blank?
        network_id = nic.dig('networkInfo', 'networkId')
        network_obj = collector.networks_by_id[network_id] if network_id

        if network_obj.nil?
          puts "WARN: No subnet or network fallback found for NIC #{index} of VM #{vm['name']}"
          network_name = "unknown"
          vlan_id = nil
        else
          network_name = network_obj.dig("spec", "name") || "unnamed-network"
          vlan_id      = network_obj.dig("spec", "vlanId")
          puts "WARN: No subnet for VM #{vm['name']} NIC #{index}, using network #{network_name} from networkId fallback"
        end
      else
        subnet = global_subnet_catalog[subnet_id]
        if subnet.nil?
          puts "WARN: No subnet found for UUID #{subnet_id} (VM: #{vm['name']})"
          network_name = "unknown-subnet"
          vlan_id = nil
        else
          network_name = subnet[:network_name]
          vlan_id      = subnet[:vlan_id]
        end
      end

      puts "DEBUG: VM #{vm['name']} NIC #{index} => IP: #{ip_address}, MAC: #{mac_address}, Subnet: #{network_name}, VLAN: #{vlan_id}"


      network = persister.networks.build(
        :hardware    => hardware,
        :description => "NIC #{index}",
        :ipaddress   => ip_address,
        :hostname    => network_name,
        :ipv6address => nil
      )

      persister.guest_devices.build(
        :hardware        => hardware,
        :uid_ems         => nic_ext_id,
        :device_name     => "NIC #{index}",
        :device_type     => 'ethernet',
        :controller_type => 'ethernet',
        :address         => mac_address,
        :network         => network,
        :lan => subnet_id ? persister.lans.lazy_find(:uid_ems => subnet_id) : nil
      )
    end
  end

  def parse_subnets
    collector.subnets.each do |subnet|
      uid_ems = subnet.dig('metadata', 'uuid') || subnet['extId']
      tag     = subnet['networkId']&.to_s
      name    = subnet['name']
      ems_ref = subnet['extId']

      # Try to find existing LAN by uid_ems
      existing_lan = Lan.find_by(uid_ems: uid_ems)

      if existing_lan
        # Update existing LAN to keep data fresh
        existing_lan.update!(
          :tag     => tag,
          :name    => name,
          :ems_ref => ems_ref,
          :type    => "ManageIQ::Providers::Nutanix::InfraManager::Lan"
        )
      else
        # Build new LAN record to be persisted later
        persister.lans.build(
          :uid_ems => uid_ems,
          :name    => name,
          :ems_ref => ems_ref,
          :tag     => tag,
          :type    => "ManageIQ::Providers::Nutanix::InfraManager::Lan"
        )
      end

      puts "DEBUG: LAN processed - uid_ems=#{uid_ems}, name=#{name}, tag=#{tag}"
    end
  end

  def parse_operating_system(vm, hardware, os_info, vm_obj)
    persister.operating_systems.build(
      :product_name   => os_info,
      :vm_or_template => vm_obj
    )
  end

  def bytes_to_human_readable(bytes)
    return nil if bytes.nil?
    units = %w[B KB MB GB TB PB]
    return '0 B' if bytes == 0

    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = units.size - 1 if exp >= units.size
    "%.2f %s" % [bytes.to_f / (1024 ** exp), units[exp]]
  end

  def parse_datastores
    collector.datastores.each do |ds|
      stats = ds.stats

      total_physical   = latest_stat(stats.storage_capacity_bytes) || ds.max_capacity_bytes
      free_physical    = latest_stat(stats.storage_free_bytes)
      used_physical    = total_physical - free_physical
      provisioned_bytes = latest_stat(stats.storage_usage_bytes) || 0

      puts "Datastore #{ds.name} stats:"
      puts "  Physical Total: #{bytes_to_human_readable(total_physical)}"
      puts "  Physical Free: #{bytes_to_human_readable(free_physical)}"
      puts "  Physical Used: #{bytes_to_human_readable(used_physical)}"
      puts "  Provisioned: #{bytes_to_human_readable(provisioned_bytes)}"

      persister.storages.build(
        :ems_ref            => ds.container_ext_id,
        :name               => ds.name,
        :store_type         => "NutanixVolume",
        :storage_domain_type => "primary",
        :total_space        => total_physical,
        :free_space         => free_physical,
        :uncommitted        => provisioned_bytes,
        :multiplehostaccess => true,
        :location           => ds.clusterName,
        :master             => true
      )
    end
  end

  def parse_host_storages
    # Associate all hosts in a cluster with its datastores
    collector.datastores.each do |ds|
      next unless (host_ids = @cluster_hosts[ds.cluster_uuid])
      
      host_ids.each do |host_id|
        persister.host_storages.build(
          :host    => persister.hosts.lazy_find(host_id),
          :storage => persister.storages.lazy_find(ds.container_ext_id)
        )
      end
    end
  end
  
  def latest_stat(stat_array)
    return 0 if stat_array.nil? || !stat_array.respond_to?(:max_by)

    stat_array.max_by(&:timestamp)&.value || 0
  end

  def parse_templates
    collector.templates.each do |template|
      persister.miq_templates.build(
        :ems_ref         => template.ext_id || template.uuid || template.id,
        :uid_ems         => template.ext_id || template.uuid || template.id,
        :name            => template.template_name || "Unnamed Template",
        :vendor          => "nutanix",
        :location        => template.try(:storage_container_path) || template.try(:uri) || "unknown-location",
        :raw_power_state => 'never'
      )
    end
  end
end