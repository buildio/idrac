require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

# Covers the LC068 anticipate-and-drain the app used to hand-roll as
# drain_pending_idrac_config_job! before every SCP import.
RSpec.describe "IDRAC LC068 config-job drain" do
  let(:client) do
    IDRAC::Client.new(host: 'idrac.example.com', username: 'root', password: 'calvin', verify_ssl: false)
  end

  before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  describe "#drain_pending_config_jobs!" do
    it "deletes every non-Completed job and keeps the Completed ones" do
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [
          { "Id" => "JID_DONE", "JobState" => "Completed" },
          { "Id" => "JID_SCHED", "JobState" => "Scheduled" },
          { "Id" => "JID_RUN", "JobState" => "Running" }] }.to_json)
      keep = stub_request(:delete, %r{/Jobs/JID_DONE}).to_return(status: 200, body: '{}')
      d1 = stub_request(:delete, %r{/Jobs/JID_SCHED}).to_return(status: 200, body: '{}')
      d2 = stub_request(:delete, %r{/Jobs/JID_RUN}).to_return(status: 200, body: '{}')

      expect(client.drain_pending_config_jobs!).to contain_exactly("JID_SCHED", "JID_RUN")
      expect(d1).to have_been_made
      expect(d2).to have_been_made
      expect(keep).not_to have_been_made
    end

    it "returns [] and deletes nothing when only Completed jobs remain" do
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [{ "Id" => "JID_DONE", "JobState" => "Completed" }] }.to_json)

      expect(client.drain_pending_config_jobs!).to eq([])
      expect(a_request(:delete, %r{/Jobs/})).not_to have_been_made
    end

    it "is best-effort: swallows a read failure and returns []" do
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?}).to_return(status: 500, body: 'boom')
      expect(client.drain_pending_config_jobs!).to eq([])
    end
  end

  describe "#set_system_configuration_profile" do
    it "drains a pending config job before importing (so the import never hits LC068)" do
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [{ "Id" => "JID_OLD", "JobState" => "Scheduled" }] }.to_json)
      del = stub_request(:delete, %r{/Jobs/JID_OLD}).to_return(status: 200, body: '{}')
      # import returns a job location; the job completes
      stub_request(:post, %r{/Actions/Oem/EID_674_Manager\.ImportSystemConfiguration})
        .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_NEW' }, body: '')
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs/JID_NEW})
        .to_return(status: 200, body: { "JobState" => "Completed", "Message" => "Imported" }.to_json)

      scp = { "FQDD" => "iDRAC.Embedded.1", "Attributes" => [{ "Name" => "X", "Value" => "Y", "Set On Import" => "True" }] }
      result = client.set_system_configuration_profile(scp)

      expect(del).to have_been_made
      expect(result[:status]).to eq(:success)
    end

    it "skips the drain when drain: false" do
      stub_request(:post, %r{/Actions/Oem/EID_674_Manager\.ImportSystemConfiguration})
        .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_NEW' }, body: '')
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs/JID_NEW})
        .to_return(status: 200, body: { "JobState" => "Completed" }.to_json)

      scp = { "FQDD" => "iDRAC.Embedded.1", "Attributes" => [{ "Name" => "X", "Value" => "Y", "Set On Import" => "True" }] }
      client.set_system_configuration_profile(scp, drain: false)

      expect(a_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})).not_to have_been_made
    end
  end
end
