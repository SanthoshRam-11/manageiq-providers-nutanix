class ManageIQ::Providers::Nutanix::InfraManager::Host < ::Host
  def self.display_name(number = 1)
    n_('Host (Nutanix)', 'Hosts (Nutanix)', number)
  end

  def provider_object(connection = nil)
    connection ||= ext_management_system.connect
    # Implement host-specific API interactions here
  end

  # Add any Nutanix-specific host methods
  def hypervisor_type
    'ahv'
  end
end
