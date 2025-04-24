# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe IDRAC::License do
  let(:client) { instance_double(IDRAC::Client) }
  let(:license_collection_response) { double(status: 200, body: File.read("spec/fixtures/redfish/licenses.json")) }
  let(:license_details_response) { double(status: 200, body: File.read("spec/fixtures/redfish/license_details.json")) }

  before do
    allow(client).to receive(:authenticated_request).with(:get, "/redfish/v1/LicenseService/Licenses").and_return(license_collection_response)
    allow(client).to receive(:authenticated_request).with(:get, "/redfish/v1/LicenseService/Licenses/FD00000011364489").and_return(license_details_response)
    allow(client).to receive(:debug)
  end

  describe "#license_info" do
    it "returns license details" do
      license_class = Class.new
      license_class.include(IDRAC::License)
      license_instance = license_class.new
      allow(license_instance).to receive(:client).and_return(client)
      
      # Need to mock both calls - first to get the collection, then to get the details
      allow(license_instance).to receive(:authenticated_request).with(:get, "/redfish/v1/LicenseService/Licenses").and_return(license_collection_response)
      allow(license_instance).to receive(:authenticated_request).with(:get, "/redfish/v1/LicenseService/Licenses/FD00000011364489").and_return(license_details_response)
      allow(license_instance).to receive(:debug)

      expected_details = JSON.parse(license_details_response.body)
      expect(license_instance.license_info).to eq(expected_details)
    end
  end

  describe "#license_version" do
    it "extracts version from license description" do
      license_class = Class.new
      license_class.include(IDRAC::License)
      license_instance = license_class.new
      allow(license_instance).to receive(:client).and_return(client)
      allow(license_instance).to receive(:authenticated_request).and_return(license_details_response)
      allow(license_instance).to receive(:debug)
      
      # Return hash
      license_data = JSON.parse(license_details_response.body)
      allow(license_instance).to receive(:license_info).and_return(license_data)

      expect(license_instance.license_version).to eq(9)
    end

    it "returns nil when no license version found" do
      license_class = Class.new
      license_class.include(IDRAC::License)
      license_instance = license_class.new
      allow(license_instance).to receive(:client).and_return(client)
      allow(license_instance).to receive(:debug)
      
      # Return a hash
      allow(license_instance).to receive(:license_info).and_return(
        {"Description" => "Some other license"}
      )

      expect(license_instance.license_version).to be_nil
    end
  end
end 