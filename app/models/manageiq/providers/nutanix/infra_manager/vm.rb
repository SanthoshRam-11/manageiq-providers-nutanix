class ManageIQ::Providers::Nutanix::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include SupportsFeatureMixin
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::RemoteConsole
  #include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Reconfigure

  # supports :reconfigure
  # supports :reconfigure_network_adapters
  # supports :reconfigure_disksize do
  #   if snapshots.count > 1
  #     'Cannot resize disks of a VM with snapshots'
  #   end
  # end

  def network_adapters
    hardware.nics.map do |nic|
      {
        :name        => nic.device_name,
        :mac_address => nic.mac_address,
        :vlan        => nic.lan&.name,
        :uid_ems     => nic.uid_ems,
        :network_uuid => nic.uid_ems  # Nutanix uses NIC UUID as network identifier
      }
    end
  end

  # Add validation for reconfigure
  def validate_reconfigure
    errors = []
    
    if snapshots.count > 1
      errors << 'Cannot reconfigure VM with snapshots'
    end
    
    if raw_power_state != 'OFF'
      errors << 'VM must be powered off for reconfiguration'
    end
    
    if errors.any?
      {:available => false, :message => errors.join('; ')}
    else
      {:available => true, :message => nil}
    end
  end

  # Better power state mapping
  POWER_STATES = {
    "ON"  => "on",
    "OFF" => "off",
  }.freeze

  supports :start do
    unsupported_reason_add(:start, _('The VM is already powered on')) if raw_power_state == 'ON'
  end
  
  supports :shutdown_guest do
    unsupported_reason_add(:shutdown_guest, _('The VM is not powered on')) unless raw_power_state == 'ON'
  end

  supports :reboot_guest do
    if raw_power_state != 'ON'
      unsupported_reason_add(:reboot_guest, _('The VM is not powered on'))
    end
  end

  supports :suspend do
    unsupported_reason_add(:suspend, _('Suspend is not supported for Nutanix VMs'))
  end

  supports :reset do
    unsupported_reason_add(:reset, _('The VM is not powered on')) unless raw_power_state == 'ON'
  end

  supports :terminate do
    unsupported_reason_add(:terminate, _('Cannot delete a running or suspended VM')) if raw_power_state != 'OFF'
  end

  supports :nutanix_reconfigure do
    unsupported_reason_add(:nutanix_reconfigure, _("VM is not powered off")) unless powered_off?
  end

  def has_required_host?
    true
  end

  def self.calculate_power_state(raw_power_state)
    POWER_STATES[raw_power_state] || super
  end

  def self.display_name(number = 1)
    n_('Virtual Machine (Nutanix)', 'Virtual Machines (Nutanix)', number)
  end

  def provider_object(connection = nil)
    connection ||= ext_management_system.connect
    api = NutanixVmm::VmApi.new(connection)
    api.get_vm(ems_ref)
  end

  # Add custom methods for UI display
  def mac_addresses
    hardware.nics.map(&:mac_address).compact
  end

  def ip_addresses
    hardware.nets.map(&:ipaddress).compact
  end

  # Add validation for reconfigure
  def validate_reconfigure
    if snapshots.count > 1
      {:available => false, :message => 'Cannot reconfigure VM with snapshots'}
    else
      {:available => true, :message => nil}
    end
  end
end
