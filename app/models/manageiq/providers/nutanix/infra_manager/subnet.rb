class ManageIQ::Providers::Nutanix::InfraManager::Subnet < ::Subnet
    scope :by_ems, ->(ems) { where(:ems_ref => ems.uid_ems) }
end
