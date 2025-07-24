class ManageIQ::Providers::Nutanix::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  def initialize_inventory_collections
    super

    # Core collections
    add_collection(infra, :vms)
    add_collection(infra, :hosts)
    add_collection(infra, :clusters)
    
    # Hardware and devices
    add_collection(infra, :hardwares)
    add_collection(infra, :host_hardwares)
    add_collection(infra, :storages)
    add_collection(infra, :disks)
    add_collection(infra, :guest_devices)
    add_collection(infra, :networks)
    add_collection(infra, :operating_systems)
    add_collection(infra, :miq_templates)
    add_collection(infra, :host_storages)
    
    # Network collections
    add_collection(infra, :switches) do |builder|
      builder.add_properties(:manager_ref => [:ems_ref])
    end
    
    add_collection(infra, :lans) do |builder|
      builder.add_properties(:manager_ref => [:ems_ref])
    end
    
    add_collection(infra, :subnets) do |builder|
      builder.add_properties(
        :manager_ref => [:ems_ref],
        :model_class => ::Subnet
      )
    end
  end
end