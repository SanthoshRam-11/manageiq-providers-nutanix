if ENV['CI']
  require 'simplecov'
  SimpleCov.start
end

Dir[Rails.root.join("spec/shared/**/*.rb")].sort.each { |f| require f }
Dir[File.join(__dir__, "support/**/*.rb")].sort.each { |f| require f }

require "manageiq/providers/nutanix"

VCR.configure do |config|
  config.ignore_hosts 'codeclimate.com' if ENV['CI']
  config.cassette_library_dir = File.join(ManageIQ::Providers::Nutanix::Engine.root, 'spec/vcr_cassettes')

  secrets = Rails.application.secrets
  %i[hostname username password].each do |key|
    config.define_cassette_placeholder(Rails.application.secrets.nutanix_defaults[key]) do
      Rails.application.secrets.nutanix[key]
    end
  end
end
