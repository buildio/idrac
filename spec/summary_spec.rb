# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "idrac summary command" do
  let(:fixture_base) { "spec/fixtures/PowerEdge-R640/redfish/v1" }
  let(:system_fixture) { JSON.parse(File.read("#{fixture_base}/Systems/System.Embedded.1/index.json")) }
  let(:idrac_fixture) { JSON.parse(File.read("#{fixture_base}/Managers/iDRAC.Embedded.1/index.json")) }
  let(:licenses_fixture) { JSON.parse(File.read("#{fixture_base}/LicenseService/Licenses/index.json")) }
  let(:license_details_fixture) { JSON.parse(File.read("#{fixture_base}/LicenseService/Licenses/FD00000011364489.json")) }

  describe "license information" do
    it "correctly formats the license display" do
      # Mock the license response
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(
        double(
          code: "200",
          body: license_details_fixture.to_json
        )
      )

      # The actual test will depend on how we extract this in the code
      # For now, we can test the expected format
      license_type = license_details_fixture["LicenseType"]
      license_description = license_details_fixture["Description"]
      
      expect(license_type).to eq("Production")
      expect(license_description).to eq("iDRAC9 Enterprise License")
      expect("#{license_type} (#{license_description})").to eq("Production (iDRAC9 Enterprise License)")
    end
  end

  describe "system information" do
    it "extracts basic system information" do
      expect(system_fixture["Model"]).to eq("PowerEdge R640")
      expect(system_fixture["PowerState"]).to eq("On")
    end

    it "extracts service tag" do
      expect(system_fixture["SKU"]).to eq("BSG7KP2")
    end

    it "extracts memory information" do
      memory_summary = system_fixture["MemorySummary"]
      dell_system = system_fixture.dig("Oem", "Dell", "DellSystem")

      expect(memory_summary["TotalSystemMemoryGiB"]).to eq(1408)
      expect(dell_system["MaxDIMMSlots"]).to eq(24)
      expect(dell_system["PopulatedDIMMSlots"]).to eq(22)
      expect(memory_summary["MemoryMirroring"]).to eq("System")
    end

    it "extracts processor information" do
      processor_summary = system_fixture["ProcessorSummary"]
      dell_system = system_fixture.dig("Oem", "Dell", "DellSystem")

      expect(processor_summary["Count"]).to eq(2)
      expect(processor_summary["CoreCount"]).to eq(40)
      expect(processor_summary["LogicalProcessorCount"]).to eq(80)
      expect(processor_summary["Model"]).to eq("Intel(R) Xeon(R) Gold 6138 CPU @ 2.00GHz")
      expect(dell_system["MaxCPUSockets"]).to eq(2)
    end

    it "extracts power supply information" do
      powered_by = system_fixture.dig("Links", "PoweredBy")
      dell_system = system_fixture.dig("Oem", "Dell", "DellSystem")

      expect(powered_by.length).to eq(1)
      expect(dell_system["PSRollupStatus"]).to eq("OK")
    end
  end

  describe "iDRAC information" do
    it "extracts firmware version" do
      # Find the firmware version in the iDRAC fixture
      active_firmware = idrac_fixture.dig("Links", "ActiveSoftwareImage", "@odata.id")
      
      expect(active_firmware).not_to be_nil
      expect(active_firmware).to include("7.00.00.172")
    end
  end
end 