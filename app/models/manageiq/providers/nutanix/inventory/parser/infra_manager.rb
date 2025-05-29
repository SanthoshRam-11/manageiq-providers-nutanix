class ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Parser
  def parse
    parse_hosts_and_clusters
    parse_templates
    collector.vms.each { |vm| parse_vm(vm) }
    parse_datastores
  end

  private

  def parse_hosts_and_clusters
    # Clusters must be parsed first
    collector.clusters.each_value do |cluster|
      persister.ems_clusters.build(
        :ems_ref => cluster[:ems_ref],
        :name => cluster[:name],  # Now using real cluster names
        :ems_id => persister.manager.id,
        :uid_ems => cluster[:ems_ref]
      )
    end

    # Hosts
    collector.hosts.each_value do |host|
      # In parse_hosts_and_clusters method
      persister.hosts.build(
        :ems_ref => host[:ems_ref],
        :name => host[:name],
        :ems_id => persister.manager.id,
        :type => 'ManageIQ::Providers::Nutanix::InfraManager::Host'  # Now matches defined class
      )
    end
  end

  def parse_vm(vm)
    # Get OS info from VM description (or other available fields)
    os_info = vm.description.to_s.match(/OS: (.+)/)&.captures&.first || 'unknown'

    # Main VM attributes
    vm_obj = persister.vms.build(
      :ems_ref          => vm.bios_uuid,
      :name             => vm.name,
      :description      => vm.description,
      :location         => vm.cluster&.ext_id || "unknown",
      :vendor           => "nutanix",
      :raw_power_state  => vm.power_state.downcase,
      :host        => persister.hosts.lazy_find(vm.host&.ext_id),
      :ems_cluster => persister.ems_clusters.lazy_find(vm.cluster&.ext_id),
      :ems_id           => persister.manager.id,
      :connection_state => "connected",
      :boot_time        => vm.create_time,
      :type             => 'ManageIQ::Providers::Nutanix::InfraManager::Vm'
    )
    hardware = persister.hardwares.build(
      :vm_or_template => vm_obj,
      :memory_mb      => vm.memory_size_bytes / 1.megabyte,
      :cpu_total_cores => vm.num_sockets * vm.num_cores_per_socket,
      :cpu_sockets    => vm.num_sockets,
      :cpu_cores_per_socket => vm.num_cores_per_socket,
      :guest_os       => os_info # Use extracted OS info
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
    ip_address = nic.network_info&.ipv4_config&.ip_address&.value rescue nil
    mac_address = nic.backing_info&.mac_address || "unknown"

      network = persister.networks.build(
        :hardware    => hardware,
        :description => "NIC #{index}",
        :ipaddress   => ip_address,
      )
      
      persister.guest_devices.build(
        :hardware       => hardware,
        :uid_ems        => nic.ext_id,
        :device_name    => "NIC #{index}",
        :device_type    => 'ethernet',
        :controller_type => 'ethernet',
        :address        => mac_address,
        :network        => network
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
      name         = ds.name rescue "unknown"
      ems_ref      = ds.ext_id || ds.uuid rescue nil
      total_space  = ds.resources&.map(&:size_bytes)&.sum rescue nil
      free_space   = nil  # Nutanix Volume Groups may not expose this directly

      persister.storages.build(
        :name        => name,
        :store_type  => 'NutanixVolume',
        :total_space => total_space,
        :free_space  => free_space,
        :ems_ref     => ems_ref
      )
    end
  end

  def parse_templates
    collector.templates.each do |template|
      persister.miq_templates.build(
        :ems_id     => persister.manager.id,
        :ems_ref    => template.ext_id || template.uuid || template.id,
        :uid_ems    => template.ext_id || template.uuid || template.id,
        :name => template.template_name || "Unnamed Template",
        :vendor     => "nutanix",
        :type       => 'ManageIQ::Providers::Nutanix::InfraManager::Template',
        :location   => template_storage_location(template),
        :raw_power_state => 'never',
        :template   => true
      )
    end
  end

  def template_storage_location(template)
    # Try different candidate fields or fallback to a dummy string
    template.try(:storage_container_path) ||
    template.try(:uri) ||
    "unknown-location"
  end

  def map_power_state(state)
    case state&.downcase
    when "on"    then "on"
    when "off"   then "off"
    else "unknown"
    end
  end
end
