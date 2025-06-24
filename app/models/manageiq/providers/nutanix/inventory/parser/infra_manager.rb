class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser
  def parse
    parse_hosts
    parse_clusters
    parse_datastores
    parse_templates
    collector.vms.each { |vm| parse_vm(vm) }
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
      persister.hosts.build(
        :ems_ref     => host.ext_id,
        :name        => host.host_name,
        :ems_cluster => ems_cluster
      )
    end
  end

  def parse_vm(vm)
    # Get OS info from VM description (or other available fields)
    os_info = vm.description.to_s.match(/OS: (.+)/)&.captures&.first || 'unknown'

    # Get primary storage from VM config
    primary_storage_uuid = vm.storage_config&.storage_container_reference&.uuid rescue nil
    primary_storage = persister.storages.lazy_find(primary_storage_uuid) if primary_storage_uuid

    # If still nil, use first available storage
    unless primary_storage
      first_storage = persister.storages.data.first
      primary_storage = first_storage.ems_ref if first_storage
    end

    # Main VM attributes
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
      :boot_time        => vm.create_time,
      :storage          => primary_storage
    )

    hardware = persister.hardwares.build(
      :vm_or_template       => vm_obj,
      :memory_mb            => vm.memory_size_bytes / 1.megabyte,
      :cpu_total_cores      => vm.num_sockets * vm.num_cores_per_socket,
      :cpu_sockets          => vm.num_sockets,
      :cpu_cores_per_socket => vm.num_cores_per_socket,
      :guest_os             => os_info # Use extracted OS info
    )
    # Then use vm_obj for subsequent associations
    parse_disks(vm, hardware)  # This should reference the hardware object
    parse_nics(vm, hardware)
    parse_operating_system(vm, hardware, os_info, vm_obj)
  end

  def parse_disks(vm, hardware)
    vm.disks.each do |disk|
      # First try to get container UUID from disk backing
      container_uuid = disk.backing_info&.storage_container_uuid rescue nil
      
      # Then try to get from VM's storage config
      if container_uuid.nil?
        container_uuid = vm.storage_config&.storage_container_reference&.uuid rescue nil
      end
      
      # Finally, fall back to the first storage container if available
      if container_uuid.nil? && persister.storages.data.any?
        container_uuid = persister.storages.data.first.ems_ref
      end

      size_bytes = disk.disk_size_bytes || disk.backing_info&.disk_size_bytes rescue nil
      
      storage = persister.storages.lazy_find(container_uuid) if container_uuid

      persister.disks.build(
        :hardware    => hardware,
        :device_name => "Disk #{disk.disk_address&.index}",
        :device_type => disk.disk_address&.bus_type,
        :size        => size_bytes,
        :location    => disk.disk_address&.index.to_s,
        :filename    => disk.ext_id,
        :storage     => storage
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

  def parse_datastores
    collector.datastores.each do |ds|
      container_uuid = ds.ext_id
      persister.storages.build(
        :ems_ref     => container_uuid,  # Use actual container UUID
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