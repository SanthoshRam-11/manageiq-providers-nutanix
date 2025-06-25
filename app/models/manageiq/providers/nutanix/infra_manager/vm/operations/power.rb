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
end