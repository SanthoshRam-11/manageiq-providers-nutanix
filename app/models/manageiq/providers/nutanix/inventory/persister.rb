class ManageIQ::Providers::Nutanix::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  def initialize_inventory_collections
    add_cloud_collection(:vms)
  end
end
