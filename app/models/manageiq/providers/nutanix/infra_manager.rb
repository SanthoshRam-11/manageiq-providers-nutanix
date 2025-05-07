class ManageIQ::Providers::Nutanix::InfraManager < ManageIQ::Providers::InfraManager
  supports :create

  def self.params_for_create
    {
      :fields => [
        {
          :component => 'sub-form',
          :name      => 'endpoints-subform',
          :title     => _('Endpoints'),
          :fields    => [
            {
              :component              => 'validate-provider-credentials',
              :name                   => 'authentications.default.valid',
              :skipSubmit             => true,
              :validationDependencies => %w[type],
              :fields                 => [
                {
                  :component    => "select",
                  :id           => "endpoints.default.verify_ssl",
                  :name         => "endpoints.default.verify_ssl",
                  :label        => _("SSL verification"),
                  :dataType     => "integer",
                  :isRequired   => true,
                  :validate     => [{:type => "required"}],
                  :initialValue => OpenSSL::SSL::VERIFY_NONE,
                  :options      => [
                    {
                      :label => _('Do not verify'),
                      :value => OpenSSL::SSL::VERIFY_NONE,
                    },
                    {
                      :label => _('Verify'),
                      :value => OpenSSL::SSL::VERIFY_PEER,
                    },
                  ]
                },
                {
                  :component  => "text-field",
                  :name       => "endpoints.default.hostname",
                  :label      => _("Hostname (or IPv4 or IPv6 address)"),
                  :isRequired => true,
                  :validate   => [{:type => "required"}],
                },
                {
                  :component    => "text-field",
                  :name         => "endpoints.default.port",
                  :label        => _("API Port"),
                  :type         => "number",
                  :initialValue => 9440, # Changed to standard Nutanix port
                  :isRequired   => true,
                  :validate     => [{:type => "required"}]
                },
                {
                  :component  => "text-field",
                  :name       => "authentications.default.userid",
                  :label      => "Username",
                  :isRequired => true,
                  :validate   => [{:type => "required"}]
                },
                {
                  :component  => "password-field",
                  :name       => "authentications.default.password",
                  :label      => "Password",
                  :type       => "password",
                  :isRequired => true,
                  :validate   => [{:type => "required"}]
                },
              ]
            }
          ]
        }
      ]
    }
  end

  def self.verify_credentials(args)
    endpoint = args.dig("endpoints", "default")
    authentication = args.dig("authentications", "default")
    
    hostname = endpoint&.dig("hostname")
    port = endpoint&.dig("port")
    verify_ssl = endpoint&.dig("verify_ssl")
    username = authentication&.dig("userid")
    password = authentication&.dig("password")
    
    !!raw_connect(hostname, port, username, password, verify_ssl)
  rescue => err
    raise MiqException::MiqInvalidCredentialsError, err.message
  end

  def verify_credentials(auth_type = nil, options = {})
    begin
      connect
      true
    rescue => err
      raise MiqException::MiqInvalidCredentialsError, err.message
    end
  end

  def connect(options = {})
    raise MiqException::MiqHostError, "No credentials defined" if missing_credentials?(options[:auth_type])

    auth_type = options[:auth_type] || 'default'
    username, password = auth_user_pwd(auth_type)
    
    self.class.raw_connect(
      default_endpoint.hostname,
      default_endpoint.port,
      username,
      password,
      default_endpoint.verify_ssl
    )
  end

  def self.raw_connect(hostname, port, username, password, verify_ssl = OpenSSL::SSL::VERIFY_NONE)
    require "nutanix_vmm"
    
    # Create configuration object
    config = NutanixVmm::Configuration.new do |config|
      config.host = "#{hostname}:#{port}"
      config.scheme = "https"
      config.verify_ssl = false
      config.verify_ssl_host = false
      config.debugging = true
      config.username = username
      config.password = password
    end
    
    # Create API client with that configuration
    api_client = NutanixVmm::ApiClient.new(config)
    
    # Return a ConnectionManager with the API clients needed
    ConnectionManager.new(api_client)
  end

  def self.ems_type
    @ems_type ||= "nutanix".freeze
  end

  def self.description
    @description ||= "Nutanix".freeze
  end

  # ConnectionManager provides access to different API instances
  class ConnectionManager
    attr_reader :api_client

    def initialize(api_client)
      @api_client = api_client
    end

    def vms_api
      @vms_api ||= NutanixVmm::VmApi.new(@api_client)
    end

    def clusters_api
      # Add Cluster API initialization when needed
      # @clusters_api ||= NutanixVmm::ClusterApi.new(@api_client)
    end

    def hosts_api
      # Add Host API initialization when needed
      # @hosts_api ||= NutanixVmm::HostApi.new(@api_client)
    end

    # Test method to verify connection is working
    def get_vms
      vms_api.list_vms_0
    end
  end
end
