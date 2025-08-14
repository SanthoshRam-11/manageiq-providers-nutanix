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
  supports :nutanix_detach_interface
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

  def nutanix_detach_interface(options = {})
    Rails.logger.info("Starting nutanix_detach_interface for VM: #{name} (#{ems_ref}) with options: #{options.inspect}")

    nic_ext_id = options[:nic_ext_id] || options["nic_ext_id"]
    if nic_ext_id.blank?
      Rails.logger.error("No nic_ext_id provided for detaching interface")
      raise MiqException::Error, "nic_ext_id parameter is required to detach interface"
    end

    # FIXED: Validate that nic_ext_id is in proper UUID format
    unless nic_ext_id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      Rails.logger.error("Invalid nic_ext_id format: #{nic_ext_id}")
      raise MiqException::Error, "nic_ext_id must be in valid UUID format"
    end

    # Ensure VM is powered off
    if raw_power_state != "OFF"
      Rails.logger.error("VM must be powered off to detach interfaces")
      raise MiqException::Error, "VM must be powered off to detach interfaces"
    end

    begin
      retries ||= 0
      max_retries = 3

      connection = ext_management_system.connect
      vm_api = NutanixVmm::VmApi.new(connection)
      
      # Get VM info for ETag
      vm_info, status, headers = vm_api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['ETag']

      if etag.blank?
        Rails.logger.error("ETag header missing from VM response")
        raise MiqException::Error, "ETag header missing from VM response"
      end

      Rails.logger.info("VM retrieved successfully, proceeding with NIC detachment")
      Rails.logger.info("Using ETag: #{etag.inspect}")
      Rails.logger.info("NIC External ID to detach: #{nic_ext_id}")

      # FIXED: Use API version 4.0 as per Nutanix documentation (not 4.1)
      path = "/api/vmm/v4.0/ahv/config/vms/#{ems_ref}/nics/#{nic_ext_id}"
      url = URI.parse(connection.config.base_url)

      full_url = "#{url.scheme}://#{url.host}:#{url.port}#{path}"
      Rails.logger.info("Sending DELETE request to: #{full_url}")

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # For testing only

      request = Net::HTTP::Delete.new(path)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request['If-Match'] = etag
      request['NTNX-Request-Id'] = SecureRandom.uuid
      
      # FIXED: Use proper authentication
      if connection.config.respond_to?(:api_key) && connection.config.api_key.present?
        request['Authorization'] = "Bearer #{connection.config.api_key}"
      else
        request.basic_auth(connection.config.username, connection.config.password)
      end
      
      response = http.request(request)

      # Enhanced error handling
      case response
      when Net::HTTPSuccess
        Rails.logger.info("Successfully detached interface #{nic_ext_id} from VM #{name}")
        Rails.logger.info("Response: #{response.body}")
        response_body = response.body.present? ? JSON.parse(response.body) : { success: true }
        return response_body
      when Net::HTTPNotFound
        Rails.logger.error("404 Not Found - NIC #{nic_ext_id} not found on VM #{ems_ref}")
        Rails.logger.error("Response body: #{response.body}")
        raise MiqException::Error, "Network interface not found. Check if the NIC ID is correct or if it was already detached."
      when Net::HTTPPreconditionFailed
        Rails.logger.error("412 Precondition Failed - ETag mismatch")
        raise MiqException::Error, "ETag mismatch - VM was modified by another process"
      when Net::HTTPBadRequest
        Rails.logger.error("400 Bad Request - #{response.body}")
        raise MiqException::Error, "Bad request: #{response.body}"
      when Net::HTTPUnauthorized
        Rails.logger.error("401 Unauthorized - Check credentials")
        raise MiqException::Error, "Authentication failed"
      when Net::HTTPForbidden
        Rails.logger.error("403 Forbidden - Insufficient permissions")
        raise MiqException::Error, "Insufficient permissions to detach interface"
      else
        Rails.logger.error("HTTP Error #{response.code}: #{response.body}")
        raise MiqException::Error, "HTTP Error #{response.code}: #{response.body}"
      end

    rescue => e
      if e.message.include?('412') && (retries += 1) <= max_retries
        Rails.logger.warn("ETag mismatch, retrying (#{retries}/#{max_retries})")
        sleep 1
        retry
      end

      Rails.logger.error("Error detaching interface: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
      
      if e.is_a?(MiqException::Error)
        raise e
      else
        raise MiqException::Error, "Nutanix API Error: #{e.message}"
      end
    end
  end

  # Add custom methods for UI display
  def mac_addresses
    hardware.nics.map(&:mac_address).compact
  end

  def ip_addresses
    hardware.nets.map(&:ipaddress).compact
  end
end
