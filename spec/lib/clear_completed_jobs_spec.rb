require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

# Queue hygiene: free iDRAC job-queue slots by deleting only jobs that have FINISHED.
# The destructive neighbours (clear_jobs!, drain_pending_config_jobs!) are covered elsewhere.
RSpec.describe "IDRAC job-queue hygiene" do
  let(:client) do
    IDRAC::Client.new(host: 'idrac.example.com', username: 'root', password: 'calvin', verify_ssl: false)
  end

  before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  def stub_queue(members)
    stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})
      .to_return(status: 200, body: { "Members" => members }.to_json)
  end

  describe "#clear_completed_jobs" do
    it "deletes every finished job and returns the ids removed" do
      stub_queue([{ "Id" => "JID_DONE", "JobState" => "Completed" },
                  { "Id" => "JID_FAILED", "JobState" => "Failed" },
                  { "Id" => "JID_ERRS", "JobState" => "CompletedWithErrors" }])
      deletes = %w[JID_DONE JID_FAILED JID_ERRS].map do |id|
        stub_request(:delete, %r{/Jobs/#{id}}).to_return(status: 200, body: '{}')
      end

      expect(client.clear_completed_jobs).to contain_exactly("JID_DONE", "JID_FAILED", "JID_ERRS")
      deletes.each { |d| expect(d).to have_been_made }
    end

    it "never touches a job that has not finished" do
      stub_queue([{ "Id" => "JID_DONE", "JobState" => "Completed" },
                  { "Id" => "JID_RUN", "JobState" => "Running" },
                  { "Id" => "JID_SCHED", "JobState" => "Scheduled" },
                  { "Id" => "JID_NEW", "JobState" => "New" }])
      done = stub_request(:delete, %r{/Jobs/JID_DONE}).to_return(status: 200, body: '{}')

      expect(client.clear_completed_jobs).to eq(["JID_DONE"])
      expect(done).to have_been_made
      %w[JID_RUN JID_SCHED JID_NEW].each do |id|
        expect(a_request(:delete, %r{/Jobs/#{id}})).not_to have_been_made
      end
    end

    it "is a clean no-op on an empty queue" do
      stub_queue([])
      expect(client.clear_completed_jobs).to eq([])
      expect(a_request(:delete, %r{/Jobs/})).not_to have_been_made
    end

    it "is a clean no-op when nothing in the queue has finished" do
      stub_queue([{ "Id" => "JID_RUN", "JobState" => "Running" }])
      expect(client.clear_completed_jobs).to eq([])
      expect(a_request(:delete, %r{/Jobs/})).not_to have_been_made
    end

    it "swallows a failed queue read and returns [] rather than raising into the caller" do
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?}).to_return(status: 500, body: 'boom')
      expect { expect(client.clear_completed_jobs).to eq([]) }.not_to raise_error
    end

    it "reports only the ids the iDRAC accepted, and keeps going after a refused delete" do
      stub_queue([{ "Id" => "JID_NO", "JobState" => "Completed" },
                  { "Id" => "JID_OK", "JobState" => "Completed" }])
      stub_request(:delete, %r{/Jobs/JID_NO}).to_return(status: 500, body: 'nope')
      ok = stub_request(:delete, %r{/Jobs/JID_OK}).to_return(status: 200, body: '{}')

      expect(client.clear_completed_jobs).to eq(["JID_OK"])
      expect(ok).to have_been_made
    end
  end

  describe "#pending_config_jobs" do
    it "returns the jobs that have not finished, and deletes nothing" do
      stub_queue([{ "Id" => "JID_DONE", "JobState" => "Completed" },
                  { "Id" => "JID_RUN", "JobState" => "Running" }])

      expect(client.pending_config_jobs.map { |j| j["Id"] }).to eq(["JID_RUN"])
      expect(a_request(:delete, %r{/Jobs/})).not_to have_been_made
    end

    it "returns [] when the queue cannot be read" do
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?}).to_return(status: 500, body: 'boom')
      expect(client.pending_config_jobs).to eq([])
    end
  end
end
