# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe IDRAC::License do
  let(:license_class) do
    Class.new do
      include IDRAC::License
      attr_accessor :verbosity
      def initialize; @verbosity = 0; end
      def debug(*); end
    end
  end
  let(:instance) { license_class.new }

  # iDRAC 9 fixtures
  let(:license_collection) { JSON.parse(File.read("spec/fixtures/redfish/licenses.json")) }
  let(:license_details) { JSON.parse(File.read("spec/fixtures/redfish/license_details.json")) }

  # iDRAC 8 fixtures
  let(:idrac8_manager) { JSON.parse(File.read("spec/fixtures/redfish/idrac8_manager.json")) }

  describe "#license_info" do
    it "returns license details for iDRAC 9" do
      allow(instance).to receive(:safe_get)
        .with("/redfish/v1/LicenseService/Licenses").and_return(license_collection)
      allow(instance).to receive(:safe_get)
        .with("/redfish/v1/LicenseService/Licenses/FD00000011364489").and_return(license_details)

      expect(instance.license_info).to eq(license_details)
    end

    it "falls through to OEM path for iDRAC 8 (LicenseService unavailable)" do
      allow(instance).to receive(:safe_get).and_return(nil)
      allow(instance).to receive(:safe_get)
        .with("/redfish/v1/Managers/iDRAC.Embedded.1").and_return(idrac8_manager)

      result = instance.license_info
      expect(result).to be_a(Hash)
      expect(result["LicenseType"]).to be_present
    end
  end

  describe "#license_version" do
    it "extracts version 9 from license description" do
      allow(instance).to receive(:license_info).and_return(license_details)
      expect(instance.license_version).to eq(9)
    end

    it "detects version 8 from server header when description lacks version" do
      allow(instance).to receive(:license_info).and_return({"Description" => "Enterprise License"})
      allow(instance).to receive(:authenticated_request)
        .with(:get, "/redfish/v1")
        .and_yield(double(status: 200, headers: {"server" => "iDRAC/8"}))

      expect(instance.license_version).to eq(8)
    end

    it "returns nil when no version can be determined" do
      allow(instance).to receive(:license_info).and_return({"Description" => "Some license"})
      allow(instance).to receive(:authenticated_request)
        .with(:get, "/redfish/v1")
        .and_yield(double(status: 200, headers: {"server" => "Apache/2.4.0"}))

      expect(instance.license_version).to be_nil
    end
  end
end
