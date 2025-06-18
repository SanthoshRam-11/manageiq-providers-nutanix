class ManageIQ::Providers::Nutanix::InfraManager < ManageIQ::Providers::InfraManager
  supports :create
  validate :hostname_uniqueness_valid?
  def allow_targeted_refresh?
    true
  end

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

  def hostname_uniqueness_valid?
    return unless hostname.present?

    existing_providers =
      self.class
          .joins(:endpoints)
          .where.not(:id => id)
          .where("LOWER(endpoints.hostname) = ?", hostname.downcase)

    if existing_providers.any?
      errors.add(:hostname, "has already been taken")
    end
  end

  def self.verify_credentials(args)
    endpoint = args.dig("endpoints", "default")
    authentication = args.dig("authentications", "default")

    hostname = endpoint&.dig("hostname")
    port = endpoint&.dig("port")
    verify_ssl = endpoint&.dig("verify_ssl") || OpenSSL::SSL::VERIFY_NONE
    username = authentication&.dig("userid")
    password = ManageIQ::Password.try_decrypt(authentication&.dig("password"))

    api_client = raw_connect(hostname, port, username, password, verify_ssl)

    # Test connection
    ConnectionManager.new(api_client).get_vms
  rescue => err
    raise MiqException::MiqInvalidCredentialsError, err.message
  end

  def verify_credentials(auth_type = nil, options = {})
    begin
      api_client = connect
      ConnectionManager.new(api_client).get_vms
      true
    rescue => err
      raise MiqException::MiqInvalidCredentialsError, err.message
    end
  end

  def connect(options = {})
    raise MiqException::MiqHostError, "No credentials defined" if missing_credentials?(options[:auth_type])

    auth_type = options[:auth_type] || 'default'
    username, password = auth_user_pwd(auth_type)

    api_client = self.class.raw_connect(
      default_endpoint.hostname,
      default_endpoint.port,
      username,
      password,
      default_endpoint.verify_ssl
    )

    # Return the appropriate service client
    case options[:service]
    when "Infra"
      ConnectionManager.new(api_client) # Return connection manager for infra services
    else
      api_client # Default to base API client
    end
  end

  def self.validate_authentication_args(params)
    # return args to be used in raw_connect
    return [params[:default_userid], ManageIQ::Password.encrypt(params[:default_password])]
  end

  def self.hostname_required?
    # TODO: ExtManagementSystem is validating this
    false
  end

  def parent_manager
    nil
  end

  def self.raw_connect(hostname, port, username, password, verify_ssl)
    require "nutanix_vmm"

    if Rails.env.development? || Rails.env.test?
      verify_ssl = OpenSSL::SSL::VERIFY_NONE
    end

    verify_ssl_bool = verify_ssl == OpenSSL::SSL::VERIFY_PEER

    # Create configuration object
    config = NutanixVmm::Configuration.new do |config|
      config.host = "#{hostname}:#{port}"
      config.scheme = "https"
      config.verify_ssl = verify_ssl_bool
      config.verify_ssl_host = verify_ssl_bool
      config.debugging = true
      config.username = username
      config.password = password
      config.base_path = "/api"
    end

    # Create API client with that configuration
    NutanixVmm::ApiClient.new(config)
  rescue => err
    raise MiqException::MiqInvalidCredentialsError, "Authentication failed: #{err.message}"
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
