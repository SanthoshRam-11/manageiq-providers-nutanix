class ManageIQ::Providers::Nutanix::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include SupportsFeatureMixin
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power

  # Completely custom logic - no host/storage check
  # Clear inherited support checks
  # Better power state mapping
  POWER_STATES = {
    "ON"  => "on",
    "on"  => "on",    # Handle lowercase
    "OFF" => "off",
    "off" => "off"    # Handle lowercase
  }.freeze

  def validate_start
    # Return nil means valid, else return error string
    nil
  end

  def validate_stop
    nil
  end
  def validate_power_operation
    return _("The VM is not connected to a Host") if host.nil?
    return _("The VM does not have a Storage") if storage.nil?
    nil
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
end
