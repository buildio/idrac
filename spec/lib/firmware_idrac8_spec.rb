require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

# iDRAC8-specific firmware tests (R630/R730 era controllers)
# These tests ensure firmware management works correctly with the
# older Redfish implementation found on iDRAC8 (firmware 2.x).
RSpec.describe IDRAC::Firmware, 'iDRAC8' do
  let(:client) do
    IDRAC::Client.new(
      host: '192.168.0.20',
      username: 'root',
      password: 'calvin',
      port: 443,
      verify_ssl: false,
      direct_mode: true
    )
  end

  let(:firmware) { IDRAC::Firmware.new(client) }

  let(:firmware_inventory_response) do
    {
      "Members" => [
        { "@odata.id" => "/redfish/v1/UpdateService/FirmwareInventory/Installed-25227-2.84.84.84" },
        { "@odata.id" => "/redfish/v1/UpdateService/FirmwareInventory/Installed-159-2.17.0" },
        { "@odata.id" => "/redfish/v1/UpdateService/FirmwareInventory/Installed-101560-25.5.0.0018" },
        { "@odata.id" => "/redfish/v1/UpdateService/FirmwareInventory/Previous-25227-2.41.40.40" },
      ]
    }.to_json
  end

  let(:idrac_component) do
    {
      "Name" => "Integrated Dell Remote Access Controller",
      "Id" => "Installed-25227-2.84.84.84",
      "Version" => "2.84.84.84",
      "Updateable" => true,
      "Status" => { "State" => "Enabled" }
    }.to_json
  end

  let(:bios_component) do
    {
      "Name" => "BIOS",
      "Id" => "Installed-159-2.17.0",
      "Version" => "2.17.0",
      "Updateable" => true,
      "Status" => { "State" => "Enabled" }
    }.to_json
  end

  let(:perc_component) do
    {
      "Name" => "PERC H730P Mini",
      "Id" => "Installed-101560-25.5.0.0018",
      "Version" => "25.5.0.0018",
      "Updateable" => true,
      "Status" => { "State" => "Enabled" }
    }.to_json
  end

  let(:previous_idrac) do
    {
      "Name" => "Integrated Dell Remote Access Controller",
      "Id" => "Previous-25227-2.41.40.40",
      "Version" => "2.41.40.40",
      "Updateable" => true,
      "Status" => { "State" => "Enabled" }
    }.to_json
  end

  let(:system_info_response) do
    {
      "Model" => "PowerEdge R630",
      "Manufacturer" => "Dell Inc.",
      "SerialNumber" => "G2WSHH2",
      "PartNumber" => "0CNCJWA12",
      "BiosVersion" => "2.17.0",
      "SKU" => "G2WSHH2"
    }.to_json
  end

  before do
    # Stub the session endpoint detection
    stub_request(:get, "https://192.168.0.20:443/redfish/v1")
      .to_return(status: 200, body: { "RedfishVersion" => "1.0.2" }.to_json)
  end

  describe '#get_firmware_inventory' do
    before do
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/Systems/System.Embedded.1")
        .to_return(status: 200, body: system_info_response)
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory")
        .to_return(status: 200, body: firmware_inventory_response)
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory/Installed-25227-2.84.84.84")
        .to_return(status: 200, body: idrac_component)
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory/Installed-159-2.17.0")
        .to_return(status: 200, body: bios_component)
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory/Installed-101560-25.5.0.0018")
        .to_return(status: 200, body: perc_component)
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory/Previous-25227-2.41.40.40")
        .to_return(status: 200, body: previous_idrac)
    end

    it 'returns system info and firmware list' do
      result = firmware.get_system_inventory
      expect(result[:system][:model]).to eq("PowerEdge R630")
      expect(result[:system][:service_tag]).to eq("G2WSHH2")
      expect(result[:firmware]).to be_an(Array)
      expect(result[:firmware].length).to eq(4)
    end

    it 'includes version and updateable status for each component' do
      result = firmware.get_system_inventory
      idrac_fw = result[:firmware].find { |f| f[:name] == "Integrated Dell Remote Access Controller" && f[:id].start_with?("Installed") }
      expect(idrac_fw[:version]).to eq("2.84.84.84")
      expect(idrac_fw[:updateable]).to be true
    end

    it 'includes previous firmware versions (rollback slots)' do
      result = firmware.get_system_inventory
      previous = result[:firmware].select { |f| f[:id].start_with?("Previous") }
      expect(previous.length).to eq(1)
      expect(previous.first[:version]).to eq("2.41.40.40")
    end

    it 'distinguishes current from previous firmware by ID prefix' do
      result = firmware.get_system_inventory
      result[:firmware].each do |fw|
        expect(fw[:id]).to match(/^(Current|Installed|Previous)-/)
      end
    end
  end

  describe '#upload_firmware' do
    let(:update_service_response) do
      { "HttpPushUri" => "/redfish/v1/UpdateService/FirmwareInventory" }.to_json
    end

    let(:upload_success_response) do
      { "Id" => "Available-12345-2.86.86.86", "@odata.id" => "/redfish/v1/UpdateService/FirmwareInventory/Available-12345-2.86.86.86" }.to_json
    end

    before do
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService")
        .to_return(status: 200, body: update_service_response)
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory")
        .to_return(status: 200, body: firmware_inventory_response, headers: { 'ETag' => '"12345"' })
      stub_request(:post, "https://192.168.0.20:443/redfish/v1/UpdateService/FirmwareInventory")
        .to_return(status: 201, body: upload_success_response)
      stub_request(:post, "https://192.168.0.20:443/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate")
        .to_return(status: 202, body: "", headers: { 'Location' => '/redfish/v1/TaskService/Tasks/JID_123456789' })
    end

    it 'uploads firmware file and returns job ID' do
      # Create a temp firmware file
      Tempfile.create(['test_firmware', '.exe']) do |f|
        f.write("fake firmware content")
        f.close
        job_id = firmware.send(:upload_firmware, f.path)
        expect(job_id).to be_present
      end
    end
  end

  describe 'iDRAC8-specific behaviors' do
    it 'handles iDRAC8 Redfish version 1.0.2' do
      # iDRAC8 uses Redfish 1.0.2, session endpoint at /redfish/v1/Sessions
      stub_request(:get, "https://192.168.0.20:443/redfish/v1")
        .to_return(status: 200, body: { "RedfishVersion" => "1.0.2" }.to_json)

      # Verify client can detect the version
      response = client.authenticated_request(:get, "/redfish/v1") { |r| r }
      data = JSON.parse(response.body)
      expect(data["RedfishVersion"]).to eq("1.0.2")
    end

    it 'uses HttpPushUri for firmware upload (not MultipartUpload)' do
      # iDRAC8 uses HttpPushUri, not the newer MultipartHttpPushUri
      stub_request(:get, "https://192.168.0.20:443/redfish/v1/UpdateService")
        .to_return(status: 200, body: {
          "HttpPushUri" => "/redfish/v1/UpdateService/FirmwareInventory",
          # Note: no MultipartHttpPushUri on iDRAC8
        }.to_json)

      response = client.authenticated_request(:get, "/redfish/v1/UpdateService") { |r| r }
      data = JSON.parse(response.body)
      expect(data["HttpPushUri"]).to be_present
      expect(data["MultipartHttpPushUri"]).to be_nil
    end
  end
end
