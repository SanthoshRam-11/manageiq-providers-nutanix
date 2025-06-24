class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser
  def parse
    parse_hosts
    parse_clusters
    parse_templates
    collector.vms.each { |vm| parse_vm(vm) }
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
      host_ref = host.ext_id.to_s.downcase

      ems_cluster = persister.clusters.lazy_find(host.cluster.uuid) if host.cluster&.uuid

      persister.hosts.build(
        :ems_ref     => host_ref,
        :name        => host.host_name,
        :ems_cluster => ems_cluster
      )
    end
  end

  def parse_vm(vm)
    # Get OS info from VM description (or other available fields)
    os_info = if vm.respond_to?(:guest_os) && vm.guest_os.present?
              vm.guest_os
            elsif vm.respond_to?(:machine_type) && vm.machine_type.present?
              vm.machine_type
            else
              vm.description.to_s.match(/OS:\s*(.+)/i)&.captures&.first || 'unknown'
            end
    host_ref = vm.host&.ext_id&.to_s
    primary_storage = if vm.respond_to?(:storage_config) && vm.storage_config
      container_ref = vm.storage_config.storage_container_reference
      container_uuid = container_ref.ext_id if container_ref
      persister.storages.lazy_find(container_uuid) if container_uuid
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
      :host             => persister.hosts.lazy_find(host_ref),
      :ems_cluster      => persister.clusters.lazy_find(vm.cluster&.ext_id),
      :ems_id           => persister.manager.id,
      :connection_state => "connected",
      :boot_time        => vm.create_time,
      :storage => primary_storage 
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
      # FIXED: Get disk size from backing_info with safe access
      size_bytes = disk.backing_info&.disk_size_bytes rescue nil
      
      # If still nil, try alternative methods
      if size_bytes.nil?
        if disk.respond_to?(:disk_size_mib)
          # Convert MiB to bytes
          size_bytes = disk.disk_size_mib * 1.megabyte if disk.disk_size_mib
        elsif disk.respond_to?(:disk_size_bytes)
          size_bytes = disk.disk_size_bytes
        end
      end

      # Get storage container with fallback and logging
      container_uuid = nil
      if disk.backing_info
        begin
          # Try to access storage container through various methods
          container_ref = disk.backing_info.storage_container_reference rescue nil
          container_ref ||= disk.backing_info.storage_container rescue nil
          
          container_uuid = container_ref.ext_id if container_ref&.respond_to?(:ext_id)
        rescue => e
          _log.error("Error accessing storage container for disk #{disk.ext_id}: #{e.message}")
        end
      end

      _log.debug("Disk #{disk.ext_id} container: #{container_uuid || 'none'}")

      persister.disks.build(
        :hardware    => hardware,
        :device_name => "Disk #{disk.disk_address&.index}",
        :device_type => disk.disk_address&.bus_type,
        :size        => size_bytes,
        :location    => disk.disk_address&.index.to_s,
        :filename    => disk.ext_id,
        :storage     => persister.storages.lazy_find(container_uuid)
      )
    end

    # CD-ROM devices
    if vm.respond_to?(:cdRoms) && vm.cdRoms
      vm.cdRoms.each do |cdrom|
        # FIXED: Get size from backing_info with safe access
        size_bytes = cdrom.backing_info&.disk_size_bytes rescue nil
        
        # If still nil, try alternative methods
        if size_bytes.nil?
          if cdrom.respond_to?(:disk_size_mib)
            # Convert MiB to bytes
            size_bytes = cdrom.disk_size_mib * 1.megabyte if cdrom.disk_size_mib
          elsif cdrom.respond_to?(:disk_size_bytes)
            size_bytes = cdrom.disk_size_bytes
          end
        end

        container_uuid = if cdrom.backing_info
          container_ref = cdrom.backing_info.try(:storage_container_reference) ||
                          cdrom.backing_info.try(:storage_container)
          
          container_ref.ext_id if container_ref&.respond_to?(:ext_id)
        end
        
        persister.disks.build(
          :hardware    => hardware,
          :device_name => "CD-ROM #{cdrom.disk_address&.index}",
          :device_type => 'cdrom',
          :size        => size_bytes,
          :location    => cdrom.disk_address&.index.to_s,
          :filename    => cdrom.ext_id,
          :storage     => persister.storages.lazy_find(container_uuid)
        )
      end
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
    puts "📦 Parsing datastores..."
    collector.datastores.each do |ds|
      puts "📂 Registering storage: #{ds.name} | ems_ref: #{ds.container_ext_id}"
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