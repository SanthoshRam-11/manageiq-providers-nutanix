class ManageIQ::Providers::Nutanix::InfraManager::Switch < ::Switch
  def ems_ref
    uid_ems
  end

  def ems_ref=(val)
    self.uid_ems = val
  end
end
