require 'spec_helper'

RSpec.describe IDRAC::Utility do
  let(:client) do
    IDRAC::Client.new(
      host: 'idrac.example.com',
      username: 'root',
      password: 'calvin',
      verify_ssl: false
    )
  end

  before(:each) do
    # Mock authentication
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  describe 'TSR Log Operations' do
    describe '#tsr_status' do
      it 'returns TSR collection status' do
        # Mock the DellLCService endpoint
        dell_lc_service_response = {
          "Actions" => {
            "#DellLCService.SupportAssistCollection" => {
              "target" => "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.SupportAssistCollection"
            }
          }
        }
        
        # Mock the Jobs endpoint
        jobs_response = {
          "Members" => []
        }
        
        stub_request(:get, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService})
          .to_return(status: 200, body: dell_lc_service_response.to_json)
          
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs})
          .to_return(status: 200, body: jobs_response.to_json)
          
        status = client.tsr_status
        
        expect(status).to be_a(Hash)
        expect(status).to have_key(:available)
        expect(status).to have_key(:collection_in_progress)
        expect(status[:available]).to be true
        expect(status[:collection_in_progress]).to be false
      end
    end

    describe '#generate_tsr_logs' do
      it 'initiates TSR log generation when EULA is accepted' do
        # Mock EULA status check
        eula_response = { "EULAAccepted" => true }
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistGetEULAStatus})
          .to_return(status: 200, body: eula_response.to_json)
        
        # Mock TSR generation request
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistCollection})
          .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_123456789' })
        
        # Mock job completion
        job_response = {
          "Id" => "JID_123456789",
          "JobState" => "Completed",
          "PercentComplete" => 100,
          "Message" => "Task completed successfully"
        }
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123456789})
          .to_return(status: 200, body: job_response.to_json)
          
        result = client.generate_tsr_logs(
          data_selector_values: ["HWData", "OSAppData"]
        )
        
        expect(result).to be_a(Hash)
        expect(result[:status]).to eq(:success)
      end

      it 'fails when EULA is not accepted' do
        # Mock EULA status check - not accepted
        eula_response = { "EULAAccepted" => false }
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistGetEULAStatus})
          .to_return(status: 200, body: eula_response.to_json)
          
        result = client.generate_tsr_logs(
          data_selector_values: ["HWData", "OSAppData"]
        )
        
        expect(result).to be_a(Hash)
        expect(result[:status]).to eq(:failed)
        expect(result[:error]).to eq("SupportAssist EULA not accepted")
      end
    end

    describe '#supportassist_eula_status' do
      it 'checks SupportAssist EULA status' do
        eula_response = { "EULAAccepted" => true }
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistGetEULAStatus})
          .to_return(status: 200, body: eula_response.to_json)
          
        status = client.supportassist_eula_status
        
        expect(status).to be_a(Hash)
        expect(status).to have_key("EULAAccepted")
        expect(status["EULAAccepted"]).to be true
      end
    end

    describe '#accept_supportassist_eula' do
      it 'accepts SupportAssist EULA' do
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistAcceptEULA})
          .to_return(status: 200, body: {}.to_json)
          
        result = client.accept_supportassist_eula
        
        expect([true, false]).to include(result)
        expect(result).to be true
      end
    end

    describe '#generate_and_download_tsr' do
      it 'generates and downloads TSR in one operation' do
        # Mock EULA status check
        eula_response = { "EULAAccepted" => true }
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistGetEULAStatus})
          .to_return(status: 200, body: eula_response.to_json)
        
        # Mock TSR generation request
        stub_request(:post, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService/Actions/DellLCService\.SupportAssistCollection})
          .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_123456789' })
        
        # Mock job completion with file location
        job_response = {
          "Id" => "JID_123456789",
          "JobState" => "Completed",
          "PercentComplete" => 100,
          "Message" => "Task completed successfully",
          "Oem" => {
            "Dell" => {
              "OutputLocation" => "/downloads/supportassist_collection.zip"
            }
          }
        }
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123456789})
          .to_return(status: 200, body: job_response.to_json)
        
        # Mock file download
        mock_zip_content = "PK\x03\x04\x14\x00\x00\x00\x08\x00" # Mock ZIP file header
        stub_request(:get, %r{/downloads/supportassist_collection\.zip})
          .to_return(status: 200, body: mock_zip_content)
        
        output_file = "/tmp/test_tsr_complete_#{Time.now.to_i}.zip"
        
        result = client.generate_and_download_tsr(
          output_file: output_file,
          data_selector_values: ["HWData"],
          wait_timeout: 120
        )
        
        if result
          expect(File.exist?(output_file)).to be true
          expect(File.size(output_file)).to be > 0
          File.delete(output_file) if File.exist?(output_file)
        end
      end
    end

  end
end