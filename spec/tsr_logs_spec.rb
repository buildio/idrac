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

    describe 'SupportAssist robustness' do
      before { allow(client).to receive(:sleep) }

      it 'tsr_status detects a running SupportAssist Collection from the expanded jobs list' do
        dell_lc_service_response = {
          "Actions" => {
            "#DellLCService.SupportAssistCollection" => {
              "target" => "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.SupportAssistCollection"
            }
          }
        }
        jobs_response = {
          "Members" => [
            { "Id" => "JID_RUN", "Name" => "SupportAssist Collection", "JobState" => "Running", "PercentComplete" => 20 }
          ]
        }
        stub_request(:get, %r{/redfish/v1/Dell/Managers/iDRAC\.Embedded\.1/DellLCService})
          .to_return(status: 200, body: dell_lc_service_response.to_json)
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs})
          .to_return(status: 200, body: jobs_response.to_json)

        status = client.tsr_status

        expect(status[:collection_in_progress]).to be true
        expect(status[:job_id]).to eq("JID_RUN")
        expect(status[:job_state]).to eq("Running")
      end

      it 'supportassist_collection_running? is true only for a non-terminal, sub-100% collection job' do
        running = { "Members" => [{ "Name" => "SupportAssist Collection", "JobState" => "Running", "PercentComplete" => 30 }] }
        done    = { "Members" => [{ "Name" => "SupportAssist Collection", "JobState" => "Completed", "PercentComplete" => 100 }] }
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
          .to_return({ status: 200, body: running.to_json }, { status: 200, body: done.to_json })

        expect(client.supportassist_collection_running?).to be true
        expect(client.supportassist_collection_running?).to be false
      end

      it 'generate_and_download_tsr waits while a collection is running, then proceeds' do
        running = { "Members" => [{ "Id" => "JID_1", "Name" => "SupportAssist Collection", "JobState" => "Running", "PercentComplete" => 10 }] }
        clear   = { "Members" => [] }
        # Expanded-jobs preflight polls: first running, then clear.
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
          .to_return({ status: 200, body: running.to_json }, { status: 200, body: clear.to_json })

        stub_request(:post, %r{DellLCService\.SupportAssistGetEULAStatus})
          .to_return(status: 200, body: { "EULAAccepted" => true }.to_json)
        stub_request(:post, %r{DellLCService\.SupportAssistCollection})
          .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_ABC' })
        job = { "Id" => "JID_ABC", "JobState" => "Completed", "PercentComplete" => 100,
                "Oem" => { "Dell" => { "OutputLocation" => "/downloads/sa.zip" } } }
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_ABC})
          .to_return(status: 200, body: job.to_json)
        stub_request(:get, %r{/downloads/sa\.zip}).to_return(status: 200, body: "PK\x03\x04payload")

        output_file = "/tmp/tsr_wait_#{Time.now.to_i}.zip"
        result = client.generate_and_download_tsr(output_file: output_file, data_selector_values: ["HWData"], wait_timeout: 120)

        expect(result).to eq(output_file)
        expect(File.exist?(output_file)).to be true
        expect(client).to have_received(:sleep).at_least(:once)
        File.delete(output_file) if File.exist?(output_file)
      end

      it 'generate_and_download_tsr accepts the EULA first when accept_eula: true' do
        # No collection running -> preflight passes immediately.
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
          .to_return(status: 200, body: { "Members" => [] }.to_json)
        stub_request(:post, %r{DellLCService\.SupportAssistGetEULAStatus})
          .to_return(status: 200, body: { "EULAAccepted" => true }.to_json)
        stub_request(:post, %r{DellLCService\.SupportAssistCollection})
          .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_ABC' })
        job = { "Id" => "JID_ABC", "JobState" => "Completed", "PercentComplete" => 100,
                "Oem" => { "Dell" => { "OutputLocation" => "/downloads/sa.zip" } } }
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_ABC})
          .to_return(status: 200, body: job.to_json)
        stub_request(:get, %r{/downloads/sa\.zip}).to_return(status: 200, body: "PK\x03\x04payload")

        expect(client).to receive(:accept_supportassist_eula).and_return(true)

        output_file = "/tmp/tsr_eula_#{Time.now.to_i}.zip"
        client.generate_and_download_tsr(output_file: output_file, accept_eula: true, wait_timeout: 60)
        File.delete(output_file) if File.exist?(output_file)
      end
    end

  end
end