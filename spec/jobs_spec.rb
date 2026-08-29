require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

RSpec.describe IDRAC::Jobs do
  let(:client) do
    IDRAC::Client.new(
      host: 'idrac.example.com',
      username: 'root',
      password: 'calvin',
      verify_ssl: false
    )
  end

  before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)

    # Mock authentication
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  describe '#jobs' do
    it 'returns job summary statistics' do
      jobs_response = {
        "Members" => [
          { "Id" => "JID_001", "JobState" => "Completed" },
          { "Id" => "JID_002", "JobState" => "Completed" },
          { "Id" => "JID_003", "JobState" => "Running" }
        ]
      }

      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs})
        .to_return(status: 200, body: jobs_response.to_json)

      result = client.jobs

      expect(result).to be_a(Hash)
      expect(result[:completed_count]).to eq(2)
      expect(result[:incomplete_count]).to eq(1)
      expect(result[:total_count]).to eq(3)
    end
  end

  describe '#jobs_detail' do
    it 'returns detailed job information' do
      jobs_response = {
        "Members" => [
          { "Id" => "JID_001", "JobState" => "Completed", "Message" => "Done", "CompletionTime" => "2024-01-01" }
        ]
      }

      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs})
        .to_return(status: 200, body: jobs_response.to_json)

      result = client.jobs_detail

      expect(result).to be_a(Hash)
      expect(result["Members"]).to be_an(Array)
      expect(result["Members"].first["Id"]).to eq("JID_001")
    end
  end

  describe '#clear_jobs!' do
    it 'clears all jobs from the queue' do
      jobs_response = {
        "Members" => [
          { "Id" => "JID_001", "JobState" => "Completed", "Message" => "Done" }
        ]
      }

      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs})
        .to_return(status: 200, body: jobs_response.to_json)

      stub_request(:delete, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_001})
        .to_return(status: 200, body: '{}')

      result = client.clear_jobs!

      expect(result).to be true
    end

    it 'returns true when no jobs to clear' do
      jobs_response = { "Members" => [] }

      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs})
        .to_return(status: 200, body: jobs_response.to_json)

      result = client.clear_jobs!

      expect(result).to be true
    end
  end

  describe '#tasks' do
    it 'returns list of tasks' do
      tasks_response = {
        "Members" => [
          { "Id" => "TASK_001", "TaskState" => "Running" }
        ]
      }

      stub_request(:get, %r{/redfish/v1/TaskService/Tasks})
        .to_return(status: 200, body: tasks_response.to_json)

      result = client.tasks

      expect(result).to be_an(Array)
      expect(result.first["Id"]).to eq("TASK_001")
    end
  end

  describe '#wait_for_job' do
    it 'waits for job completion and returns job data' do
      job_response = {
        "Id" => "JID_123",
        "JobState" => "Completed",
        "Message" => "Job completed successfully",
        "CompletionTime" => "2024-01-01T12:00:00"
      }

      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123})
        .to_return(status: 200, body: job_response.to_json)

      result = client.wait_for_job("JID_123")

      expect(result).to be_a(Hash)
      expect(result["JobState"]).to eq("Completed")
    end

    it 'raises error when job fails' do
      job_response = {
        "Id" => "JID_123",
        "JobState" => "Failed",
        "Message" => "Job failed"
      }

      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123})
        .to_return(status: 200, body: job_response.to_json)

      expect {
        client.wait_for_job("JID_123")
      }.to raise_error(IDRAC::Error, /Job failed/)
    end
  end

  describe '#wait_for_job_completion' do
    def job(state, message)
      { status: 200, body: { "Id" => "JID_123", "JobState" => state, "Message" => message }.to_json }
    end

    it 'returns the job outcome, including the job id, when the job completes' do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123})
        .to_return(job("Running", "Importing configuration"),
                   job("Completed", "Successfully imported and applied Server Configuration Profile"))

      result = client.wait_for_job_completion("JID_123")

      expect(result[:status]).to eq(:success)
      expect(result[:job_id]).to eq("JID_123")
      expect(result[:job_state]).to eq("Completed")
      expect(result[:message]).to match(/Successfully imported/)
      expect(result[:job]["Id"]).to eq("JID_123")
    end

    %w[Failed CompletedWithErrors RebootFailed].each do |state|
      it "surfaces the job's own message when the job is #{state}" do
        stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123})
          .to_return(job(state, "Unable to apply attribute ServerBoot.1#FirstBootDevice"))

        result = client.wait_for_job_completion("JID_123")

        expect(result[:status]).to eq(:failed)
        expect(result[:job_state]).to eq(state)
        expect(result[:error]).to eq("Unable to apply attribute ServerBoot.1#FirstBootDevice")
        expect(result[:messages]).to eq(["Unable to apply attribute ServerBoot.1#FirstBootDevice"])
      end
    end

    it 'accepts a location header instead of a bare job id' do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123})
        .to_return(job("Completed", "Done"))

      expect(client.wait_for_job_completion("/redfish/v1/TaskService/Tasks/JID_123")[:job_id]).to eq("JID_123")
    end

    it 'keeps polling when the job is briefly unreadable' do
      calls = [-> { raise IDRAC::Error, "Connection reset" },
               -> { double("response", status: 200, body: { "JobState" => "Completed", "Message" => "Done" }.to_json) }]
      allow(client).to receive(:authenticated_request) { calls.shift.call }

      expect(client.wait_for_job_completion("JID_123")[:status]).to eq(:success)
    end

    it 'reports a timeout with the job id and last state' do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_123})
        .to_return(job("Running", "Still going"))

      result = client.wait_for_job_completion("JID_123", timeout: 0.05)

      expect(result[:status]).to eq(:timeout)
      expect(result[:job_id]).to eq("JID_123")
      expect(result[:error]).to match(/JID_123/)
    end
  end

  describe '#wait_for_task' do
    it 'keeps waiting on a queued task instead of calling "Pending" a failure' do
      stub_request(:get, %r{/redfish/v1/TaskService/Tasks/JID_123})
        .to_return({ status: 200,
                     body: { "TaskState" => "Pending", "TaskStatus" => "OK",
                             "Messages" => [{ "Message" => "New job." }] }.to_json },
                   { status: 200, body: { "TaskState" => "Completed", "TaskStatus" => "OK" }.to_json })

      expect(client.wait_for_task("JID_123")).to eq({ status: :success })
    end

    it 'accepts a full location header' do
      stub_request(:get, %r{/redfish/v1/TaskService/Tasks/JID_123$})
        .to_return(status: 200, body: { "TaskState" => "Completed", "TaskStatus" => "OK" }.to_json)

      expect(client.wait_for_task("/redfish/v1/TaskService/Tasks/JID_123")).to eq({ status: :success })
    end

    it 'still reports a genuinely failed task' do
      stub_request(:get, %r{/redfish/v1/TaskService/Tasks/JID_123})
        .to_return(status: 200,
                   body: { "TaskState" => "Exception", "TaskStatus" => "Critical",
                           "Messages" => [{ "Message" => "Import failed" }] }.to_json)

      result = client.wait_for_task("JID_123")

      expect(result[:status]).to eq(:failed)
      expect(result[:error]).to eq("Import failed")
    end
  end
end
