class ManageIQ::Providers::Nutanix::Inventory::Persister::InfraManager < ManageIQ::Providers::Nutanix::Inventory::Persister
  def initialize_inventory_collections
    super

    # Core collections
    add_collection(infra, :vms) do |builder|
      builder.add_properties(
        :model_class => ::ManageIQ::Providers::Nutanix::InfraManager::Vm,
        :manager_ref => [:ems_ref],
        :attributes => [
          :ems_ref, :name, :description, :location, :vendor,
          :raw_power_state, :power_state, :host_id, :ems_cluster_id,
          :ems_id, :connection_state, :boot_time, :type
        ]
      )
    end

    add_collection(infra, :hosts) do |builder|
      builder.add_properties(
        :model_class => ::Host,
        :manager_ref => [:ems_ref],
        :attributes => [:ems_ref, :name, :ems_id, :type]
      )
    end

    add_collection(infra, :ems_clusters) do |builder|
      builder.add_properties(
        :model_class => ::EmsCluster,
        :manager_ref => [:ems_ref],
        :attributes => [:ems_ref, :name, :ems_id, :uid_ems]
      )
    end

    # Hardware and devices
    add_collection(infra, :hardwares) do |builder|
      builder.add_properties(
        :model_class => ::Hardware,
        :manager_ref => [:vm_or_template],
        :attributes => [
          :memory_mb, :cpu_total_cores, :cpu_sockets,
          :cpu_cores_per_socket, :guest_os, :vm_or_template
        ]
      )
    end

    add_collection(infra, :storages) do |builder|
      builder.add_properties(
        :model_class => ::Storage,
        :manager_ref => [:ems_ref],
        :attributes => [
          :ems_ref, :name, :store_type, :total_space, :free_space, :uncommitted
        ]
      )
    end

    add_collection(infra, :disks) do |builder|
      builder.add_properties(
        :model_class => ::Disk,
        :manager_ref => [:hardware, :device_name],
        :attributes => [
          :device_name, :device_type, :size, :location, :filename, :hardware
        ]
      )
    end

    add_collection(infra, :guest_devices) do |builder|
      builder.add_properties(
        :model_class => ::GuestDevice,
        :manager_ref => [:hardware, :uid_ems],
        :attributes => [
          :uid_ems, :device_name, :device_type, :controller_type,
          :address, :network, :hardware
        ]
      )
    end

    add_collection(infra, :networks) do |builder|
      builder.add_properties(
        :model_class => ::Network,
        :manager_ref => [:hardware, :description],
        :attributes => [
          :description, :ipaddress, :hardware
        ]
      )
    end

    add_collection(infra, :operating_systems) do |builder|
      builder.add_properties(
        :model_class => ::OperatingSystem,
        :manager_ref => [:vm_or_template],
        :attributes => [
          :product_name, :vm_or_template, :hardware
        ]
      )
    end

    add_collection(infra, :miq_templates) do |builder|
      builder.add_properties(
        :model_class => ::ManageIQ::Providers::Nutanix::InfraManager::Template,
        :manager_ref => [:ems_ref],
        :attributes => [:ems_ref, :name, :vendor, :type, :location, :ems_id]
      )
    end
  end
end
