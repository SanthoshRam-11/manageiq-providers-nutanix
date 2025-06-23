module ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power
  extend ActiveSupport::Concern
  included do
    supports :start do
      unsupported_reason_add(:start, _("The VM is not connected to a Host")) if host.nil?
    end

    supports :stop do
      unsupported_reason_add(:stop, _("The VM is not connected to a Host")) if host.nil?
    end
  end

  # included do
  #   # Existing shelve operations
  #   supports :start
  #   supports :shelve do
  #     if %w[on off suspended paused].exclude?(current_state)
  #       _("The VM can't be shelved, current state has to be powered on, off, suspended or paused")
  #     end
  #   end

  #   supports :shelve_offload do
  #     if current_state != "shelved"
  #       _("The VM can't be shelved offload, current state has to be shelved")
  #     end
  #   end
  # end

  def start
    raw_start
  rescue => err
    raise MiqException::MiqVmError, _("Start operation failed: %{message}") % {:message => err.message}
  end

  def fetch_vm_with_headers
    with_provider_connection(:service => :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)
      vm_data, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      [vm_data, headers]
    end
  end


  def raw_start
    vm_data, headers = fetch_vm_with_headers
    etag = headers['etag'] || headers['ETag']
    raise "ETag missing from VM GET response" if etag.nil?

    request_id = SecureRandom.uuid

    with_provider_connection(:service => :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)
      api.power_on_vm_0(ems_ref, etag, request_id)
    end

    update!(:raw_power_state => "OFF")
  end


  def raw_stop
    vm_data, headers = fetch_vm_with_headers
    etag = headers['etag'] || headers['ETag']
    raise "ETag missing from VM GET response" if etag.nil?

    request_id = SecureRandom.uuid

    with_provider_connection(:service => :VMM) do |connection|
      api = ::NutanixVmm::VmApi.new(connection)
      api.power_off_vm_0(ems_ref, etag, request_id)
    end

    update!(:raw_power_state => "ON")
  end

  def raw_pause
    raise NotImplementedError, _("Pause operation is not supported for Nutanix VMs")
  end

  def raw_suspend
    raise NotImplementedError, _("Suspend operation is not supported for Nutanix VMs")
  end

  private

  def with_provider_connection(options = {})
    connection = ext_management_system.connect(**options)
    yield(connection)
  end

end