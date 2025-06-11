class ManageIQ::Providers::Nutanix::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  def initialize_inventory_collections
    super

    # Core collections
    add_collection(infra, :vms)
    add_collection(infra, :hosts)
    add_collection(infra, :clusters)
    # Hardware and devices
    add_collection(infra, :hardwares)
    add_collection(infra, :storages)
    add_collection(infra, :disks)
    add_collection(infra, :guest_devices)
    add_collection(infra, :networks)
    add_collection(infra, :operating_systems)
    add_collection(infra, :miq_templates)
  end
end
