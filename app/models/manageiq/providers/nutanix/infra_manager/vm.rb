class ManageIQ::Providers::Nutanix::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include SupportsFeatureMixin
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::RemoteConsole
  include ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Reconfigure

  supports :reconfigure
  supports :reconfigure_network_adapters
  supports :reconfigure_disksize do
    'Cannot resize disks of a VM with snapshots' if snapshots.count > 1
  end
  supports :nutanix_attach_interface
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

  def nutanix_attach_interface(options = {})
    Rails.logger.info("Starting nutanix_attach_interface for VM: #{name} (#{ems_ref}) with options: #{options.inspect}")

    network_id = options[:network_id] || options["network_id"]
    if network_id.blank?
      Rails.logger.error("No network_id provided for attaching interface")
      raise MiqException::Error, "network_id parameter is required to attach interface"
    end

    # Ensure VM is powered off
    if raw_power_state != "OFF"
      Rails.logger.error("VM must be powered off to attach interfaces")
      raise MiqException::Error, "VM must be powered off to attach interfaces"
    end

    begin
      retries ||= 0
      max_retries = 3
      
      # Get connection from EMS
      connection = ext_management_system.connect
      
      # Get VM info and ETag
      vm_api = NutanixVmm::VmApi.new(connection)
      vm_info, status, headers = vm_api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['ETag']
      
      if etag.blank?
        Rails.logger.error("ETag header missing from VM response")
        raise MiqException::Error, "ETag header missing from VM response"
      end

      # Prepare NIC payload
      payload = {
        backingInfo: {
          model: "VIRTIO",
          isConnected: true
        },
        networkInfo: {
          nicType: "NORMAL_NIC",
          subnet: {
            extId: network_id
          }
        }
      }

      # Correct API path with /api prefix
      path = "/api/vmm/v4.0/ahv/config/vms/#{ems_ref}/nics"
      url = URI.parse(connection.config.base_url)
      full_url = "#{url.scheme}://#{url.host}:#{url.port}#{path}"

      # Use ETag exactly as received from the API
      Rails.logger.info("Using ETag: #{etag.inspect}")

      # Create HTTP request
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # For testing only
      
      request = Net::HTTP::Post.new(path)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request['If-Match'] = etag  # Use exactly as received
      request['NTNX-Request-Id'] = SecureRandom.uuid
      request.basic_auth(connection.config.username, connection.config.password)
      request.body = payload.to_json

      # Log full request details for debugging
      Rails.logger.info("Sending request to: #{full_url}")
      Rails.logger.info("Headers: #{request.each_header.map{|k,v| "#{k}: #{v}"}.join(', ')}")
      Rails.logger.info("Payload: #{payload.to_json}")

      # Send request and handle response
      response = http.request(request)
      
      unless response.is_a?(Net::HTTPSuccess)
        raise "HTTP Error #{response.code}: #{response.body}"
      end

      Rails.logger.info("Successfully attached interface to VM #{name}")
      return JSON.parse(response.body)

    rescue => e
      if e.message.include?('412') && (retries += 1) <= max_retries
        Rails.logger.warn("ETag mismatch, retrying (#{retries}/#{max_retries})")
        sleep 1
        retry
      end
      
      Rails.logger.error("Error attaching interface: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
      raise MiqException::Error, "Nutanix API Error: #{e.message}"
    end
  end
end
