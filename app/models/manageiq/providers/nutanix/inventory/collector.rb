class ManageIQ::Providers::Nutanix::Inventory::Collector < ManageIQ::Providers::Inventory::Collector
  require_nested :InfraManager
  #def connection
  #  @connection ||= manager.connect
  #end

  #def vms
  #  connection.vms
  #end
end
