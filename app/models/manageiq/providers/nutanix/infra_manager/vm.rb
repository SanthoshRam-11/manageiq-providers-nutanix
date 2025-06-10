class ManageIQ::Providers::Nutanix::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  POWER_STATES = {
    "ON"  => "on",
    "OFF" => "off"
  }.freeze

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

  def raw_stop
    conn = ext_management_system.connect(:service => :VMM)
    api = ::NutanixVmm::VmApi.new(conn)

    # Fetch the ETag needed for the request
    _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
    etag = headers['etag'] || headers['ETag']
    request_id = SecureRandom.uuid

    # Send the power-off request
    api.power_off_vm_0(ems_ref, etag, request_id)
  end
end
