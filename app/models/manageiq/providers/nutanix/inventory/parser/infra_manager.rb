class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser
  def parse
    @cluster_hosts = Hash.new { |h, k| h[k] = [] }
    parse_hosts
    parse_clusters
    parse_templates
    collector.vms.each { |vm| parse_vm(vm) }
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
    # Get OS info from VM description (or other available fields)
    os_info = vm.description.to_s.match(/OS: (.+)/)&.captures&.first || 'unknown'

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
      :boot_time        => vm.create_time
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
      # Get disk size from backing info
      size_bytes = disk.backing_info&.disk_size_bytes rescue nil

      persister.disks.build(
        :hardware    => hardware,
        :device_name => "Disk #{disk.disk_address&.index}",
        :device_type => disk.disk_address&.bus_type,
        :size        => size_bytes,
        :location    => disk.disk_address&.index.to_s,
        :filename    => disk.ext_id,
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
      stats = ds.stats

      total_space       = latest_stat(stats.storage_capacity_bytes)
      free_space        = latest_stat(stats.storage_free_bytes)
      provisioned_space = latest_stat(stats.storage_usage_bytes)

      percent_free = (free_space.to_f / total_space * 100).round(2) rescue nil
      cluster_hosts = @cluster_hosts[ds.cluster_uuid] || []
      total_hosts = cluster_hosts.size
      puts "Datastore #{ds.name} stats:"
      puts "  total_space: #{total_space}"
      puts "  free_space: #{free_space}"
      puts "  provisioned_space: #{provisioned_space}"

      persister.storages.build(
        :ems_ref            => ds.container_ext_id,
        :name               => ds.name,
        :store_type         => "NutanixVolume",
        :total_space        => total_space,
        :free_space         => free_space,
        :uncommitted        => provisioned_space,
        :multiplehostaccess => true,
        :location           => ds.clusterName
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