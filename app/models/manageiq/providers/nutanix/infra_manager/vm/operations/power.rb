module ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::Power
  extend ActiveSupport::Concern
  included do
    supports :start do
      if raw_power_state == 'ON'
        unsupported_reason_add(:start, _('The VM is already powered on'))
      end
    end
  end

  def start
    raw_start
  rescue => err
    raise MiqException::MiqVmError, _("Start operation failed: %{message}") % {:message => err.message}
  end

  def raw_start
    with_provider_connection do |connection|
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
    with_provider_connection do |connection|
      api = ::NutanixVmm::VmApi.new(connection)

      _, _, headers = api.get_vm_by_id_0_with_http_info(ems_ref)
      etag = headers['etag'] || headers['ETag']
      raise "ETag missing from VM GET response" if etag.nil?

      request_id = SecureRandom.uuid
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

  def with_provider_connection
    connection = ext_management_system.connect(:service => :VMM)
    yield(connection)
  end
end