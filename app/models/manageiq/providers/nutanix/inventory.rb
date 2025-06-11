class ManageIQ::Providers::Nutanix::Inventory < ManageIQ::Providers::Inventory
  def self.parser_classes_for(ems, target)
    case target
    when InventoryRefresh::TargetCollection
      [ManageIQ::Providers::Nutanix::Inventory::Parser::InfraManager]
    else
      super
    end
  end
end
