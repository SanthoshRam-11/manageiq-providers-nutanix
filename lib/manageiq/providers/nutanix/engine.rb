module ManageIQ
  module Providers
    module Nutanix
      class Engine < ::Rails::Engine
        isolate_namespace ManageIQ::Providers::Nutanix

        config.autoload_paths << root.join('lib').to_s

        initializer :append_secrets do |app|
          app.config.paths["config/secrets"] << root.join("config", "secrets.defaults.yml").to_s
          app.config.paths["config/secrets"] << root.join("config", "secrets.yml").to_s
        end

        initializer "manageiq.providers.nutanix.vendor_registration", :after => :load_config_initializers do
          if defined?(::VmOrTemplate::VENDOR_TYPES) && !::VmOrTemplate::VENDOR_TYPES.include?("nutanix")
            ::VmOrTemplate::VENDOR_TYPES << "nutanix"
          end
        end

        def self.vmdb_plugin?
          true
        end

        def self.plugin_name
          _('Nutanix Provider')
        end

        def self.init_loggers
          $nutanix_log ||= Vmdb::Loggers.create_logger("nutanix.log")
        end

        def self.apply_logger_config(config)
          Vmdb::Loggers.apply_config_value(config, $nutanix_log, :level_nutanix)
        end
      end
    end
  end
end
