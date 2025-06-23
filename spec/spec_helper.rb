# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "idrac"
require "webmock/rspec"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Configure WebMock
  WebMock.disable_net_connect!(allow_localhost: true)

  config.before(:each) do
    # Stub all forms of sleep to prevent delays during tests
    allow(Kernel).to receive(:sleep)
    allow_any_instance_of(Object).to receive(:sleep)
    
    # Set up fixture base path
    fixture_base = "spec/fixtures/PowerEdge-R640/redfish/v1"

    # Load fixtures
    @system_fixture = JSON.parse(File.read("#{fixture_base}/Systems/System.Embedded.1/index.json"))
    @idrac_fixture = JSON.parse(File.read("#{fixture_base}/Managers/iDRAC.Embedded.1/index.json"))
    @licenses_fixture = JSON.parse(File.read("#{fixture_base}/LicenseService/Licenses/index.json"))
    @license_details_fixture = JSON.parse(File.read("#{fixture_base}/LicenseService/Licenses/FD00000011364489.json"))

    # Stub common Redfish endpoints with proper paths
    stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1$})
      .to_return(status: 200, body: @system_fixture.to_json)

    stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1$})
      .to_return(status: 200, body: @idrac_fixture.to_json)

    stub_request(:get, %r{/redfish/v1/LicenseService/Licenses$})
      .to_return(status: 200, body: @licenses_fixture.to_json)

    stub_request(:get, %r{/redfish/v1/LicenseService/Licenses/FD00000011364489$})
      .to_return(status: 200, body: @license_details_fixture.to_json)
  end
end
