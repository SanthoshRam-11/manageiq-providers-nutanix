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
  supports :nutanix_reconfigure
  supports :nutanix_disk_details
  supports :nutanix_network_details

  def nutanix_disk_details(userid = nil, taskid = nil, args = nil)
    disks = provider_object.to_hash[:data][:disks] || []
    result = disks.map do |disk|
      {
        disk_type: disk.dig(:deviceProperties, :deviceType),
        controller_type: disk.dig(:diskAddress, :busType),
        size_gb: disk[:diskSizeBytes] ? disk[:diskSizeBytes] / 1.gigabyte : nil,
        storage_name: disk.dig(:storageContainer, :name) || 'N/A',
      }
    end

    if taskid
      task = MiqTask.find(taskid)
      task.update_status(taskid, "Finished", "Ok", "Fetched Nutanix disk details")
      task.update!(:context_data => result)
    end

    result
  end


  def nutanix_network_details(userid = nil, taskid = nil, args = nil)
    vm_hash = provider_object.to_hash
    nics = vm_hash[:data][:nics] || []

    result = nics.map do |nic|
      subnet_ext_id = nic.dig(:networkInfo, :subnet, :extId)
      private_ip = nic.dig(:networkInfo, :ipv4Config, :ipAddress, :value)

      {
        subnet_ext_id: subnet_ext_id,
        vlan_id: nil,  # No direct VLAN ID found, maybe via subnet or VPC API if available
        private_ip: private_ip,
        public_ip: nil  # Not found here
      }
    end

    if taskid
      task = MiqTask.find(taskid)
      task.update_status(taskid, "Finished", "Ok", "Fetched Nutanix network details")
      task.update!(:context_data => result)
    end

    result
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
    vm_response = api.get_vm_by_id_0(ems_ref)

    # Log the raw response for debugging
    $log.info("Nutanix VM SDK response for ems_ref=#{ems_ref}: #{vm_response.to_hash.inspect}")

    vm_response
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
