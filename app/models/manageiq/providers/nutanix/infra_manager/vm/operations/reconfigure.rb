module ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Reconfigure
  def reconfigurable?
    active?
  end

  def max_total_vcpus
    128
  end

  def max_cpu_cores_per_socket
    16
  end

  def max_vcpus
    64
  end

  def max_memory_mb
    1.terabyte / 1.megabyte
  end

  def build_config_spec(task_options)
    task_options.deep_stringify_keys!

    {
      :num_vcpus    => task_options["number_of_cpus"]&.to_i,
      :memory_mb    => task_options["vm_memory"]&.to_i,
      :disk_resize  => (spec_for_disks_edit(task_options["disk_resize"]) if task_options["disk_resize"]),
      :network_edit => (spec_for_network_adapters(task_options) if task_options["network_adapter_edit"])
    }.compact
  end

  def spec_for_disks_edit(disks)
    disks.collect do |d|
      disk = hardware.disks.find_by(:device_name => d["disk_name"])
      raise MiqException::MiqVmError, "Disk '#{d["disk_name"]}' not found" unless disk
      raise MiqException::MiqVmError, "New size must be greater than current" unless disk_size_valid?(disk.size, d["disk_size_in_mb"])

      {
        :disk_uuid => disk.uid_ems,
        :new_size  => d["disk_size_in_mb"].to_i.megabytes
      }
    end
  end

  def spec_for_network_adapters(options)
    options["network_adapter_edit"].collect do |nic|
      nic_record = hardware.nics.find_by(:device_name => nic["name"])
      raise MiqException::MiqVmError, "NIC '#{nic["name"]}' not found" unless nic_record

      {
        :nic_uuid      => nic_record.uid_ems,
        :new_network   => nic["network"]
      }
    end
  end

  def disk_size_valid?(current_size, new_size_str)
    new_size = Integer(new_size_str)
    new_size.megabytes >= current_size
  rescue
    false
  end

  def raw_reconfigure(spec)
    with_provider_connection(:service => :VMM) do |connection|
      api = NutanixVmm::VmApi.new(connection)
      
      # Fetch VM with ETag
      vm, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag']
      raise "ETag missing for VM #{ems_ref}" unless etag

      # Calculate cores per socket if provided
      cores_per_socket = spec[:cores_per_socket] || vm.spec.num_vcpus_per_socket
      num_sockets = spec[:num_vcpus].to_i / cores_per_socket

      # Build VM spec - use correct keys!
      vm_spec = {
        num_vcpus_per_socket: cores_per_socket,
        num_sockets: num_sockets,
        memory_size_mib: spec[:memory_mb]
      }.compact

      # Update VM configuration
      api.update_vm_by_id(
        ems_ref,
        spec: vm_spec,
        metadata: { etag: etag }
      )

      # Process disk resize using correct API endpoint
      process_disk_resize(api, spec[:disk_resize]) if spec[:disk_resize]

      # Process network updates
      process_network_update(api, spec[:network_edit]) if spec[:network_edit]
    end
  rescue => err
    raise "Reconfiguration failed: #{err.message}"
  end

  private

  def process_disk_resize(api, disk_specs)
    disk_specs.each do |disk|
      # Use correct disk resize endpoint
      api.update_disk(
        disk[:disk_uuid],
        disk_size: disk[:new_size],
        op: "UPDATE"
      )
    end
  end

  def process_network_update(api, network_specs)
    network_specs.each do |nic|
      # Use correct NIC update endpoint
      api.update_nic(
        nic[:nic_uuid],
        network_uuid: nic[:new_network],
        op: "UPDATE"
      )
    end
  end

end
