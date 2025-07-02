module ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power
  extend ActiveSupport::Concern

  def raw_start
    with_provider_connection(:service => :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)

      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      raise "ETag missing from VM GET response" if etag.nil?

      request_id = SecureRandom.uuid
      api.power_on_vm_0(ems_ref, etag, request_id)
    end

    update!(:raw_power_state => "OFF")
  end

  def raw_stop
    with_provider_connection(:service => :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)

      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      raise "ETag missing from VM GET response" if etag.nil?

      request_id = SecureRandom.uuid
      api.power_off_vm_0(ems_ref, etag, request_id)
    end

    update!(:raw_power_state => "ON")
  end

  def raw_shutdown_guest
    with_provider_connection(service: :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)

      # Step 1: Get VM config to check NGT status
      vm = api.get_vm_by_id_0(ems_ref)
      
      unless vm.data.is_agent_vm
        _log.warn("NGT not installed on VM #{name}, falling back to ACPI shutdown")
        return raw_shutdown_acpi  # New method - see below
      end

      # Proceed with NGT shutdown if installed...
      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      request_id = SecureRandom.uuid
      transition_config = NutanixVmm::VmmV40AhvConfigGuestPowerStateTransitionConfig.new(
        should_enable_script_exec: false,
        should_fail_on_script_failure: false
      )
      power_options = NutanixVmm::VmmV40AhvConfigGuestPowerOptions.new(
        guest_power_state_transition_config: transition_config
      )

      # Execute shutdown and monitor task
      response = api.shutdown_guest_vm_0(ems_ref, etag, request_id, power_options)
      task_id = response.data.ext_id
      monitor_task(connection, task_id)  # New method - see below
    end
  end

  # New helper: Monitor task completion
  def monitor_task(connection, task_id)
    task_api = ::NutanixVmm::TaskApi.new(connection)
    start_time = Time.now
    timeout = 300 # 5 minutes

    loop do
      task = task_api.get_task_by_id(task_id)
      case task.status
      when 'SUCCEEDED'
        break true
      when 'FAILED'
        raise "Shutdown task failed: #{task.message}"
      else # QUEUED/RUNNING
        raise 'Timeout waiting for shutdown' if Time.now - start_time > timeout
        sleep 10
      end
    end
  end

  # New method: ACPI fallback shutdown
  def raw_shutdown_acpi
    with_provider_connection(service: :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)
      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      request_id = SecureRandom.uuid
      api.shutdown_vm(ems_ref, etag, request_id)
    end
  end

  def raw_reboot_guest
    with_provider_connection(service: :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)

      vm = api.get_vm_by_id_0(ems_ref)
      unless vm.data.is_agent_vm
        _log.warn("NGT not installed on VM #{name}, falling back to ACPI reboot")
        return raw_restart_acpi
      end

      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      request_id = SecureRandom.uuid

      transition_config = NutanixVmm::VmmV40AhvConfigGuestPowerStateTransitionConfig.new(
        should_enable_script_exec: false,
        should_fail_on_script_failure: false
      )
      power_options = NutanixVmm::VmmV40AhvConfigGuestPowerOptions.new(
        guest_power_state_transition_config: transition_config
      )

      response = api.reboot_guest_vm_0(ems_ref, etag, request_id, power_options)
      monitor_task(connection, response.data.ext_id)
    end
  end

  # def raw_restart_acpi
  #   with_provider_connection(service: :VMM) do |connection|
  #     api = ::NutanixVmm::VmApi.new(connection)
  #     _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
  #     etag = headers['etag'] || headers['ETag']
  #     request_id = SecureRandom.uuid
  #     api.reboot_vm(ems_ref, etag, request_id)
  #   end
  # end

  def raw_reset
    with_provider_connection(service: :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)

      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      raise "ETag missing from VM GET response" if etag.nil?

      request_id = SecureRandom.uuid
      api.reset_vm_0(ems_ref, etag, request_id)
    end
  end

  def raw_delete
    with_provider_connection(service: :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)
      api.delete_vm_0(ems_ref)
    end
  end
end