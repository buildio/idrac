require "spec_helper"
require "idrac"
require "webmock/rspec"

RSpec.describe "idrac power methods" do
  let(:fixture_base) { "spec/fixtures/PowerEdge-R640/redfish/v1" }
  let(:power_fixture) { File.read("#{fixture_base}/Chassis/System.Embedded.1/Power.json") }
  
  before do
    WebMock.disable_net_connect!(allow_localhost: true)
    
    # Mock any HTTP requests
    allow_any_instance_of(Net::HTTP).to receive(:request).and_return(
      double(
        code: "200",
        body: power_fixture
      )
    )
  end
  
  describe "#get_power_usage_watts" do
    it "returns power consumption in watts" do
      # Create a client instance directly with the Power module
      client = Class.new { include IDRAC::Power }.new
      
      # Mock the login method to avoid actual login
      allow(client).to receive(:login)
      allow(client).to receive(:authenticated_request).and_return(
        double(
          status: 200,
          body: power_fixture
        )
      )
      
      # Test the method
      watts = client.get_power_usage_watts
      expect(watts).to eq(158.0)
    end
    
    it "raises an error when power data request fails" do
      # Create a client instance directly with the Power module
      client = Class.new { include IDRAC::Power }.new
      
      # Mock the login method to avoid actual login
      allow(client).to receive(:login)
      allow(client).to receive(:authenticated_request).and_return(
        double(
          status: 500,
          body: '{"error": {"message": "Internal Server Error"}}'
        )
      )
      
      # Test that an error is raised
      expect {
        client.get_power_usage_watts
      }.to raise_error(IDRAC::Error, /Failed to get power usage/)
    end
  end
end 