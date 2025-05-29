class ManageIQ::Providers::Nutanix::InfraManager::Refresher < ManageIQ::Providers::BaseManager::Refresher
  def parse_inventory(ems, target, _association)
    $log.info("Starting Nutanix refresh for #{ems.name} with target #{target.inspect}")
    collector = ManageIQ::Providers::Nutanix::Inventory::Collector::InfraManager.new(ems, target)
    parser    = ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager.new
    persister = ManageIQ::Providers::Nutanix::Inventory::Persister::InfraManager.new(ems)

    parser.collector = collector
    parser.persister = persister

    parser.parse

    persister.persist!
    $log.info("Completed Nutanix refresh for #{ems.name}")
  end
end
