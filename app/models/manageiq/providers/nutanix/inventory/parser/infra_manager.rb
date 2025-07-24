class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser
  def parse
    puts "DEBUG: In parser#parse, total VMs = #{collector.vms.count}"
    parse_hosts
    parse_clusters
    parse_templates
    collector.vms.each do |vm|
      puts "DEBUG: Parsing VM #{vm['name']} (#{vm['extId']})"
      parse_vm(vm)
    end
    parse_datastores
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
      ems_cluster = persister.clusters.lazy_find(host.cluster.uuid) if host.cluster&.uuid

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
    parse_nics(vm, hardware)
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

  def parse_nics(vm, hardware)
    (vm['nics'] || []).each_with_index do |nic, index|
      ip_address  = nic.dig('networkInfo', 'ipv4Config', 'ipAddress', 'value')
      mac_address = nic.dig('backingInfo', 'macAddress') || "unknown"
      subnet_id   = nic.dig('networkInfo', 'subnetReference', 'uuid')  # Prism Central style
      subnet      = collector.subnets_by_id[subnet_id]
      if subnet
        subnet_name = subnet["name"]
        vlan_id     = subnet["vlan_id"] || subnet.dig("spec", "vlan_id")
      end
      next if ip_address.nil?

      device_name = "NIC #{index}"
      network_name = subnet ? subnet["spec"]["name"] : "unknown"
      vlan_id      = subnet ? subnet["spec"]["vlan_id"] : nil
      puts "DEBUG: NIC #{index} => IP: #{ip_address}, MAC: #{mac_address}, Subnet: #{network_name}, VLAN: #{vlan_id}"
      network = persister.networks.build(
        :hardware    => hardware,
        :description => device_name,
        :ipaddress   => ip_address,
        :hostname    => network_name,
        :ipv6address => nil
      )

      persister.guest_devices.build(
        :hardware        => hardware,
        :uid_ems         => nic['extId'],
        :device_name     => device_name,
        :device_type     => 'ethernet',
        :controller_type => 'ethernet',
        :address         => mac_address,
        :network         => network
      )
    end
  end

  def parse_operating_system(vm, hardware, os_info, vm_obj)
    persister.operating_systems.build(
      :product_name   => os_info,
      :vm_or_template => vm_obj
    )
  end

  def parse_datastores
    collector.datastores.each do |ds|
      persister.storages.build(
        :ems_ref     => ds.container_ext_id,
        :name        => ds.name,
        :store_type  => "NutanixVolume",
        :total_space => ds.max_capacity_bytes
      )
    end
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