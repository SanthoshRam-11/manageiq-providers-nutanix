module ManageIQ::Providers::Nutanix::InfraManager::Vm::Operations::RemoteConsole
    extend ActiveSupport::Concern

    # included do
    #   supports :console
    #   supports :html5_console
    #   supports :vnc_console
    # end

    def console_supported?(type)
      %w(HTML5 VNC).include?(type.to_s.upcase)
    end

    def validate_remote_console_acquire_ticket(protocol, options = {})
      unless console_supported?(protocol)
        raise MiqException::RemoteConsoleNotSupportedError,
              "#{protocol} protocol is not supported for Nutanix VMs"
      end

      raise MiqException::RemoteConsoleNotSupportedError,
            "VM is not associated with a management system" if ext_management_system.nil?

      options[:check_if_running] = true unless options.key?(:check_if_running)
      if options[:check_if_running] && raw_power_state != "ON"
        raise MiqException::RemoteConsoleNotSupportedError,
              "Nutanix remote console requires the VM to be running"
      end
    end

    # def remote_console_acquire_ticket(_userid, _originating_server, console_type)
    # console_type = console_type.to_s.upcase
    # unless %w[VNC HTML5].include?(console_type)
    #     raise MiqException::RemoteConsoleNotSupportedError, "Unsupported console type #{console_type}"
    # end

    # vm_uuid = ems_ref.split('/').last
    # vm_name = name

    # console_url = "https://#{ext_management_system.hostname}/console/vnc_auto.html?path=proxy/#{vm_uuid}&name=#{URI.encode_www_form_component(vm_name)}"

    # { :remote_url => console_url, :proto => 'remote' }
    # end
    def remote_console_acquire_ticket(userid, originating_server, console_type)
      vm_uuid = ems_ref.split('/').last
      vm_name = self.name

      console_url = "http://192.168.210.154:8081/console/vnc_auto.html?path=proxy/#{vm_uuid}&name=#{URI.encode_www_form_component(vm_name)}"

      _log.info("Nutanix remote console URL: #{console_url}")

      {
        remote_url: console_url,
        proto: 'remote'
      }
    rescue => e
      _log.error("Failed to build console URL: #{e.message}")
      raise MiqException::Error, "Could not acquire console ticket: #{e.message}"
    end

    def remote_console_acquire_ticket_queue(protocol, userid)
      task_opts = {
        :action => "Acquiring Nutanix VM #{name} #{protocol.to_s.upcase} remote console ticket for user #{userid}",
        :userid => userid
      }

      queue_opts = {
        :class_name  => self.class.name,
        :instance_id => id,
        :method_name => 'remote_console_acquire_ticket',
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => 'ems_operations',
        :zone        => my_zone,
        :args        => [userid, MiqServer.my_server.id, protocol]
      }

      MiqTask.generic_action_with_callback(task_opts, queue_opts)
    end
end
