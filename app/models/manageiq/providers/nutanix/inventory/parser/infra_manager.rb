class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser

  def parser_class
    ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager
  end

  def collect_inventory_for_targets(ems, targets)
    targets.collect do |target|
      collector = ManageIQ::Providers::Nutanix::Inventory::Collector::InfraManager.new(ems, target)
      persister = ManageIQ::Providers::Nutanix::Inventory::Persister::InfraManager.new(ems, target)
      parser    = parser_class.new(collector, persister) # ✅ Fix: pass args

      parser.parse

      inventory = Inventory::InventoryCollection.new(
        persister.inventory_collections
      )

      [target, inventory]
    end
  end

  def parse
    @cluster_hosts = Hash.new { |h, k| h[k] = [] }
    parse_hosts
    parse_clusters
    parse_templates
    collector.vms.each do |vm|
      next if vm.nil?  # ✅ Prevent crash on nil VM
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
    os_info = vm.description.to_s.match(/OS: (.+)/)&.captures&.first || 'unknown'

    raw_vm = fetch_raw_vm_by_id(vm.ext_id)
    raw_disks = raw_vm["disks"] if raw_vm

    vm_obj = persister.vms.build(
      :ems_ref          => vm.ext_id,
      :uid_ems          => vm.bios_uuid,
      :name             => vm.name,
      :description      => vm.description,
      :location         => vm.cluster&.ext_id || "unknown",
      :vendor           => "nutanix",
      :raw_power_state  => vm.power_state,
      :host             => persister.hosts.lazy_find(vm.host&.ext_id),
      :ems_cluster      => persister.clusters.lazy_find(vm.cluster&.ext_id),
      :ems_id           => persister.manager.id,
      :connection_state => "connected",
      :boot_time        => vm.create_time
    )

    hardware = persister.hardwares.build(
      :vm_or_template       => vm_obj,
      :memory_mb            => vm.memory_size_bytes / 1.megabyte,
      :cpu_total_cores      => vm.num_sockets * vm.num_cores_per_socket,
      :cpu_sockets          => vm.num_sockets,
      :cpu_cores_per_socket => vm.num_cores_per_socket,
      :guest_os             => os_info
    )

    # ✅ FIXED: now passing raw_disks to parse_disks
    parse_disks(vm, hardware, raw_disks)
    parse_nics(vm, hardware)
    parse_operating_system(vm, hardware, os_info, vm_obj)
  end

  def extract_disk_backing_info(disk)
    raw_disk = nil
    disk_size_bytes = nil
    storage_container_uuid = nil

    # Safely get raw disk hash
    if disk.respond_to?(:instance_variable_get)
      raw_disk = disk.instance_variable_get(:@raw) rescue nil
    end

    if raw_disk.is_a?(Hash)
      backing = raw_disk["backing_info"] || raw_disk["backingInfo"]
      if backing
        disk_size_bytes = backing["disk_size_bytes"] || backing["diskSizeBytes"]

        container = backing["storage_container"] || backing["storageContainer"]
        if container.is_a?(Hash)
          storage_container_uuid = container["ext_id"] || container["uuid"] || container["id"]
        end
      end
    end

    # Fallbacks (optional)
    disk_size_bytes ||= disk.try(:backing_info)&.try(:disk_size_bytes)
    storage_container_uuid ||= disk.try(:backing_info)&.try(:storage_container)&.try(:ext_id)

    [disk_size_bytes, storage_container_uuid]
  end

  def fetch_raw_vm_by_id(vm_id)
    connection = @collector.connection
    response = connection.get("/api/vmm/v4.0/ahv/config/vms/#{vm_id}")
    JSON.parse(response.body)["data"]
  rescue => e
    $log.error("Error fetching raw VM #{vm_id}: #{e}")
    nil
  end

  def parse_disks(vm, hardware, raw_disks = nil)
    vm.disks.each_with_index do |disk, index|
      raw_disk = raw_disks&.find { |d| d["extId"] == disk.ext_id } if raw_disks

      # Extract disk size and storage container UUID with fallbacks
      disk_size_bytes = 0
      storage_container_uuid = nil

      if raw_disk
        backing_info = raw_disk["backingInfo"] || raw_disk["backing_info"]
        if backing_info
          disk_size_bytes = backing_info["diskSizeBytes"] || backing_info["disk_size_bytes"] || 0
          container = backing_info["storageContainer"] || backing_info["storage_container"]
          storage_container_uuid = container["extId"] || container["ext_id"] || container["uuid"] if container
        end
      else
        disk_size_bytes = disk.size_bytes if disk.respond_to?(:size_bytes)
        storage_container_uuid = disk.storage_container.ext_id if disk.respond_to?(:storage_container) && disk.storage_container
      end

      disk_size_mb = disk_size_bytes.to_i / 1.megabyte

      # Add debug print here:
      puts "Disk ##{index} for VM #{vm.name} (ext_id: #{disk.ext_id}):"
      puts "  Size (bytes): #{disk_size_bytes}"
      puts "  Size (MB): #{disk_size_mb}"
      puts "  Storage Container UUID: #{storage_container_uuid}"
      puts "  Disk Address Bus Type: #{disk.disk_address&.bus_type}"

      persister.disks.build(
        :hardware         => hardware,
        :device_name      => "Disk #{index}",
        :device_type      => "disk",
        :controller_type  => disk.disk_address&.bus_type&.downcase || "scsi",
        :size             => disk_size_mb,
        :location         => "unknown",
        :filename         => disk.ext_id,
        :storage          => persister.storages.lazy_find(storage_container_uuid),
        :present          => true,
        :start_connected  => true
      )
    end
  end

  def parse_nics(vm, hardware)
    vm.nics.each_with_index do |nic, index|
      # Get IP/MAC from NIC structure
      ip_address  = nic.network_info&.ipv4_config&.ip_address&.value rescue nil
      mac_address = nic.backing_info&.mac_address || "unknown"

      next if ip_address.nil?

      network = persister.networks.build(
        :hardware    => hardware,
        :description => "NIC #{index}",
        :ipaddress   => ip_address,
        :ipv6address => nil
      )

      persister.guest_devices.build(
        :hardware        => hardware,
        :uid_ems         => nic.ext_id,
        :device_name     => "NIC #{index}",
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