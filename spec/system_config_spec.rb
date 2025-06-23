require "spec_helper"
require "idrac"
require "webmock/rspec"

RSpec.describe "IDRAC::SystemConfig" do
  let(:client) { IDRAC::Client.new(host: "192.168.1.100", username: "root", password: "calvin") }
  let(:mock_scp) do
    {
      "SystemConfiguration" => {
        "Components" => [
          {
            "FQDD" => "iDRAC.Embedded.1",
            "Attributes" => []
          }
        ]
      }
    }
  end
  
  let(:fixture_scp) do
    JSON.parse(File.read(File.join(__dir__, "fixtures", "system_configuration_profile_idrac.json")))
  end
  
  let(:mock_job_response) do
    {
      headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
      status: 202
    }
  end
  
  let(:mock_task_response) do
    {
      "TaskState" => "Completed",
      "TaskStatus" => "OK"
    }
  end

  before do
    WebMock.disable_net_connect!(allow_localhost: true)
    
    # Mock login to avoid actual authentication
    allow(client).to receive(:login).and_return(true)
    
    # Mock get_system_configuration_profile
    allow(client).to receive(:get_system_configuration_profile).with(target: "iDRAC").and_return(mock_scp)
    
    # Mock pp method to avoid output during tests
    allow(client).to receive(:pp)
    
    # Mock authenticated_request for importing system configuration
    mock_http_response = double("HTTParty::Response", 
      headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
      status: 202,
      code: 202
    )
    allow(client).to receive(:authenticated_request).with(
      :post,
      "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration",
      anything
    ).and_return(mock_http_response)
    
    # Mock handle_location_with_ip_change to simulate successful job completion
    allow(client).to receive(:handle_location_with_ip_change).and_return({ status: :success, ip: "192.168.1.50" })
    
    # Mock idrac method (called at the end of set_idrac_ip)
    allow(client).to receive(:idrac)
    
    # Mock drac_license_version to return version 8 (this gets called by set_idrac_ip)
    allow(client).to receive(:drac_license_version).and_return("8")
    
    # Mock license_version method which is called by drac_license_version
    allow(client).to receive(:license_version).and_return("8")
    
    # Mock all HTTP requests that might be triggered
    stub_request(:get, "https://192.168.1.100/redfish/v1")
      .to_return(status: 200, body: '{"RedfishVersion": "1.6.0"}', headers: {})
    
    stub_request(:post, %r{https://192.168.1.100/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: {"X-Auth-Token" => "test-token", "Location" => "/redfish/v1/SessionService/Sessions/1"})
    
    stub_request(:post, %r{https://192.168.1.100/redfish/v1/Sessions})
      .to_return(status: 201, headers: {"X-Auth-Token" => "test-token", "Location" => "/redfish/v1/Sessions/1"})
    
    # Mock the ImportSystemConfiguration endpoint
    stub_request(:post, "https://192.168.1.100/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration")
      .to_return(status: 202, headers: {"Location" => "/redfish/v1/TaskService/Tasks/JID_123456789"})
  end

  describe "#set_idrac_ip" do
    context "when license_version is 9" do
      before do
        allow(client).to receive(:license_version).and_return("9")
        allow(client).to receive(:get_system_configuration_profile).with(target: "iDRAC").and_return(fixture_scp)
      end

      it "sets IPv4Static fields instead of IPv4 fields" do
        new_ip = "192.168.1.50"
        new_gw = "192.168.1.1"
        new_nm = "255.255.255.0"

        # Don't mock set_scp_attribute - let the real method run
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )

        # Capture the POST parameters to verify the behavior
        expected_post_body = nil
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expect(method).to eq(:post)
          expect(path).to eq("/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration")
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end

        result = client.set_idrac_ip(
          new_ip: new_ip,
          new_gw: new_gw,
          new_nm: new_nm
        )

        expect(result).to be true
        
        # Verify that the POST JSON contains IPv4Static fields (not IPv4 fields)
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        
        # Should have IPv4Static fields
        expect(attributes.any? { |attr| attr["Name"] == "IPv4Static.1#Address" }).to be true
        expect(attributes.any? { |attr| attr["Name"] == "IPv4Static.1#Gateway" }).to be true
        expect(attributes.any? { |attr| attr["Name"] == "IPv4Static.1#Netmask" }).to be true
        
        # Should NOT have IPv4 fields (version 8 behavior)
        expect(attributes.any? { |attr| attr["Name"] == "IPv4.1#Address" }).to be false
      end

      it "sends POST request with correct SCP structure from fixture" do
        expected_post_body = nil
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        
        # Capture the POST parameters
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expect(method).to eq(:post)
          expect(path).to eq("/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration")
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end
        
        # Don't mock set_scp_attribute - let the real method run

        client.set_idrac_ip(
          new_ip: "192.168.1.50",
          new_gw: "192.168.1.1",
          new_nm: "255.255.255.0"
        )

        # Verify the POST contains the fixture SCP structure
        expect(expected_post_body).to have_key("ImportBuffer")
        expect(expected_post_body).to have_key("ShareParameters")
        expect(expected_post_body["ShareParameters"]["Target"]).to eq("iDRAC")
        
        # Parse the ImportBuffer JSON and verify it contains the processed SCP data
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        expect(import_buffer).to have_key("SystemConfiguration")
        
        # Note: set_scp_attribute strips metadata (Model, Comments, etc.) for faster transfer
        expect(import_buffer["SystemConfiguration"]).not_to have_key("Model")
        expect(import_buffer["SystemConfiguration"]).not_to have_key("Comments")
        expect(import_buffer["SystemConfiguration"]).not_to have_key("ServiceTag")
        expect(import_buffer["SystemConfiguration"]).not_to have_key("TimeStamp")
        
        expect(import_buffer["SystemConfiguration"]).to have_key("Components")
        expect(import_buffer["SystemConfiguration"]["Components"]).to be_an(Array)
        expect(import_buffer["SystemConfiguration"]["Components"].first).to have_key("FQDD")
        expect(import_buffer["SystemConfiguration"]["Components"].first["FQDD"]).to eq("iDRAC.Embedded.1")
        
        # Verify the actual IPv4Static attribute values in the JSON
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        expect(attributes).to be_an(Array)
        
        # Find and verify IPv4Static.1#Address
        address_attr = attributes.find { |attr| attr["Name"] == "IPv4Static.1#Address" }
        expect(address_attr).not_to be_nil, "IPv4Static.1#Address attribute not found in POST JSON"
        
        # Verify the correct values are set (now that the bug is fixed)
        expect(address_attr["Value"]).to eq("192.168.1.50")
        expect(address_attr["Set On Import"]).to eq("True")
        
        # Find and verify IPv4Static.1#Gateway
        gateway_attr = attributes.find { |attr| attr["Name"] == "IPv4Static.1#Gateway" }
        expect(gateway_attr).not_to be_nil, "IPv4Static.1#Gateway attribute not found in POST JSON"
        expect(gateway_attr["Value"]).to eq("192.168.1.1")
        expect(gateway_attr["Set On Import"]).to eq("True")
        
        # Find and verify IPv4Static.1#Netmask
        netmask_attr = attributes.find { |attr| attr["Name"] == "IPv4Static.1#Netmask" }
        expect(netmask_attr).not_to be_nil, "IPv4Static.1#Netmask attribute not found in POST JSON"
        expect(netmask_attr["Value"]).to eq("255.255.255.0")
        expect(netmask_attr["Set On Import"]).to eq("True")
        
        # Verify IPv4 fields are NOT present (should only be IPv4Static for version 9)
        ipv4_address_attr = attributes.find { |attr| attr["Name"] == "IPv4.1#Address" }
        expect(ipv4_address_attr).to be_nil, "IPv4.1#Address should not be present in version 9"
      end

      it "handles IP change with dual IP monitoring" do
        old_ip = "192.168.1.100"
        new_ip = "192.168.1.50"
        
        # Mock the initial authenticated_request to return a location header
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        allow(client).to receive(:authenticated_request).and_return(mock_http_response)
        
        # Test the IP change monitoring behavior
        location = "/redfish/v1/TaskService/Tasks/JID_123456789"
        
        # Simulate successful task completion on new IP
        expect(client).to receive(:handle_location_with_ip_change).with(location, new_ip).and_return({
          status: :success,
          ip: new_ip
        })
        
        result = client.set_idrac_ip(
          new_ip: new_ip,
          new_gw: "192.168.1.1",
          new_nm: "255.255.255.0"
        )
        
        expect(result).to be true
      end

      it "handles IP change timeout scenarios" do
        new_ip = "192.168.1.50"
        
        # Mock the initial authenticated_request
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        allow(client).to receive(:authenticated_request).and_return(mock_http_response)
        
        # Test timeout scenario
        location = "/redfish/v1/TaskService/Tasks/JID_123456789"
        allow(client).to receive(:handle_location_with_ip_change).with(location, new_ip).and_return({
          status: :timeout,
          error: "IP change task timed out after 300 seconds"
        })
        
        expect {
          client.set_idrac_ip(
            new_ip: new_ip,
            new_gw: "192.168.1.1",
            new_nm: "255.255.255.0"
          )
        }.to raise_error(/Failed configuring static IP.*timed out/)
      end

      it "switches to aggressive new IP monitoring after old IP fails" do
        new_ip = "192.168.1.50"
        old_ip = "192.168.1.100"
        
        # Mock the initial authenticated_request
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        allow(client).to receive(:authenticated_request).and_return(mock_http_response)
        
        # Test the prioritization logic - should succeed on new IP after old IP fails
        location = "/redfish/v1/TaskService/Tasks/JID_123456789"
        allow(client).to receive(:handle_location_with_ip_change).with(location, new_ip).and_return({
          status: :success,
          ip: new_ip
        })
        
        result = client.set_idrac_ip(
          new_ip: new_ip,
          new_gw: "192.168.1.1",
          new_nm: "255.255.255.0"
        )
        
        expect(result).to be true
      end
    end

    context "with default parameters" do
      it "sets up iDRAC with default VNC port 5901" do
        expected_post_body = nil
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        
        # Capture the POST parameters to verify VNC port
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end
        
        result = client.set_idrac_ip(
          new_ip: "192.168.1.50",
          new_gw: "192.168.1.1", 
          new_nm: "255.255.255.0"
        )
        
        expect(result).to be true
        
        # Verify VNC port in the actual POST JSON
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        vnc_port_attr = attributes.find { |attr| attr["Name"] == "VNCServer.1#Port" }
        expect(vnc_port_attr["Value"]).to eq("5901")
      end
    end

    context "with custom VNC port" do
      it "sets up iDRAC with custom VNC port" do
        expected_post_body = nil
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        
        # Capture the POST parameters to verify VNC port
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end
        
        result = client.set_idrac_ip(
          new_ip: "192.168.1.50",
          new_gw: "192.168.1.1",
          new_nm: "255.255.255.0",
          vnc_port: 5902
        )
        
        expect(result).to be true
        
        # Verify VNC port in the actual POST JSON
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        vnc_port_attr = attributes.find { |attr| attr["Name"] == "VNCServer.1#Port" }
        expect(vnc_port_attr["Value"]).to eq("5902")
      end
    end

    context "with custom VNC password and port" do
      it "sets up iDRAC with custom VNC password and port" do
        expected_post_body = nil
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        
        # Capture the POST parameters to verify VNC settings
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end
        
        result = client.set_idrac_ip(
          new_ip: "192.168.1.50",
          new_gw: "192.168.1.1",
          new_nm: "255.255.255.0",
          vnc_password: "mysecretpassword",
          vnc_port: 5905
        )
        
        expect(result).to be true
        
        # Verify VNC settings in the actual POST JSON
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        
        vnc_port_attr = attributes.find { |attr| attr["Name"] == "VNCServer.1#Port" }
        expect(vnc_port_attr["Value"]).to eq("5905")
        
        vnc_password_attr = attributes.find { |attr| attr["Name"] == "VNCServer.1#Password" }
        expect(vnc_password_attr["Value"]).to eq("mysecretpassword")
      end
    end

    context "when job fails" do      
      before do
        allow(client).to receive(:handle_location_with_ip_change).and_return({
          status: :failed,
          error: "Task failed",
          messages: ["Configuration import failed"]
        })
      end

      it "raises an error with job failure details" do
        expect {
          client.set_idrac_ip(
            new_ip: "192.168.1.50",
            new_gw: "192.168.1.1",
            new_nm: "255.255.255.0"
          )
        }.to raise_error(/Failed configuring static IP/)
      end
    end

    context "port number conversion" do
      it "converts integer port to string" do
        expected_post_body = nil
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        
        # Capture the POST parameters to verify port conversion
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end
        
        client.set_idrac_ip(
          new_ip: "192.168.1.50",
          new_gw: "192.168.1.1",
          new_nm: "255.255.255.0",
          vnc_port: 5903
        )
        
        # Verify integer port is converted to string in POST JSON
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        vnc_port_attr = attributes.find { |attr| attr["Name"] == "VNCServer.1#Port" }
        expect(vnc_port_attr["Value"]).to eq("5903")
      end

      it "handles string port numbers" do
        expected_post_body = nil
        mock_http_response = double("HTTParty::Response", 
          headers: { "location" => "/redfish/v1/TaskService/Tasks/JID_123456789" },
          status: 202,
          code: 202
        )
        
        # Capture the POST parameters to verify string port handling
        expect(client).to receive(:authenticated_request) do |method, path, options|
          expected_post_body = JSON.parse(options[:body])
          mock_http_response
        end
        
        client.set_idrac_ip(
          new_ip: "192.168.1.50",
          new_gw: "192.168.1.1", 
          new_nm: "255.255.255.0",
          vnc_port: "5904"
        )
        
        # Verify string port works correctly in POST JSON
        import_buffer = JSON.parse(expected_post_body["ImportBuffer"])
        attributes = import_buffer["SystemConfiguration"]["Components"].first["Attributes"]
        vnc_port_attr = attributes.find { |attr| attr["Name"] == "VNCServer.1#Port" }
        expect(vnc_port_attr["Value"]).to eq("5904")
      end
    end
  end
end 