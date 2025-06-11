class ManageIQ::Providers::Nutanix::Inventory::Collector < ManageIQ::Providers::Inventory::Collector
  require "nutanix_vmm"
  require "nutanix_clustermgmt"

  private

  def cluster_mgmt_connection
    @cluster_mgmt_connection ||= begin
      require "nutanix_clustermgmt"

      #verify_ssl_bool = Rails.env.test? ? OpenSSL::SSL::VERIFY_NONE : (manager.default_endpoint.verify_ssl == OpenSSL::SSL::VERIFY_PEER)

      config = NutanixClustermgmt::Configuration.new do |c|
        c.scheme          = "https"
        c.host            = "#{manager.default_endpoint.hostname}:#{manager.default_endpoint.port}"
        c.username        = manager.authentication_userid
        c.password        = manager.authentication_password
        c.verify_ssl      = OpenSSL::SSL::VERIFY_NONE
        c.verify_ssl_host = false
      end

      NutanixClustermgmt::ApiClient.new(config).tap do |client|
        client.default_headers['Accept-Encoding'] = 'identity'
      end
    end
  end

  def vmm_connection
    @vmm_connection ||= begin
      require "nutanix_vmm"

      #verify_ssl_bool = Rails.env.test? ? OpenSSL::SSL::VERIFY_NONE : (manager.default_endpoint.verify_ssl == OpenSSL::SSL::VERIFY_PEER)

      # Create configuration object
      config = NutanixVmm::Configuration.new do |c|
        c.scheme          = "https"
        c.host            = "#{manager.default_endpoint.hostname}:#{manager.default_endpoint.port}"
        c.username        = manager.authentication_userid
        c.password        = manager.authentication_password
        c.verify_ssl      = OpenSSL::SSL::VERIFY_NONE
        c.verify_ssl_host = false
        c.base_path       = "/api"
      end

      # Create API client with that configuration
      NutanixVmm::ApiClient.new(config)
    end
  end
end