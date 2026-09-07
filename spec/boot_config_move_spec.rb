# frozen_string_literal: true

require "spec_helper"
require "idrac"
require "webmock/rspec"

# The BootSources / config-job / one-time-CD-boot mechanics moved out of the app's raw Redfish
# (radfish #40). The radfish-idrac adapter and the radfish facade only expose these; the logic lives
# here on IDRAC::Client (modules IDRAC::Boot and IDRAC::Jobs).
RSpec.describe "iDRAC boot/config-job mechanics (radfish #40)" do
  let(:client) do
    IDRAC::Client.new(host: "idrac.example.com", username: "root", password: "calvin", verify_ssl: false)
  end

  before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { "X-Auth-Token" => "mock-token", "Location" => "/redfish/v1/SessionService/Sessions/1" })
  end

  def boot_sources(*names_enabled)
    seq = names_enabled.each_with_index.map do |(name, enabled), i|
      { "Id" => "Boot#{i.to_s.rjust(4, '0')}", "Index" => i, "Name" => name, "Enabled" => enabled }
    end
    { "Attributes" => { "UefiBootSeq" => seq } }
  end

  describe "#stale_uefi_boot_entries" do
    it "returns the still-enabled Unknown.Unknown.* placeholders and nothing else" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(
          ["Unknown.Unknown.1-1", true], ["Unknown.Unknown.2-2", false], ["NIC.PxeDevice.1-1", true]
        ).to_json)

      entries = client.stale_uefi_boot_entries
      expect(entries.map { |e| e["Name"] }).to eq(["Unknown.Unknown.1-1"])
    end

    it "honors a custom match" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(["Optical.iDRACVirtual.1-1", true]).to_json)

      expect(client.stale_uefi_boot_entries(match: /Optical/).first["Name"]).to eq("Optical.iDRACVirtual.1-1")
    end
  end

  describe "#disable_boot_entries" do
    it "no-ops (returns []) when nothing stale is enabled" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(["NIC.PxeDevice.1-1", true]).to_json)

      expect(client.disable_boot_entries).to eq([])
    end

    it "drains first, PATCHes a sequence with the stale entries disabled, POSTs the config job, returns the names" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(
          ["Unknown.Unknown.1-1", true], ["NIC.PxeDevice.1-1", true]
        ).to_json)
      # drain_pending_config_jobs! reads the queue -- nothing pending here.
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [] }.to_json)
      patch = stub_request(:patch, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources/Settings$})
        .with { |req| body = JSON.parse(req.body); seq = body.dig("Attributes", "UefiBootSeq")
                seq.find { |e| e["Name"] == "Unknown.Unknown.1-1" }["Enabled"] == false &&
                seq.find { |e| e["Name"] == "NIC.PxeDevice.1-1" }["Enabled"] == true }
        .to_return(status: 200, body: "{}")
      job = stub_request(:post, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs$})
        .with { |req| JSON.parse(req.body)["TargetSettingsURI"] == "/redfish/v1/Systems/System.Embedded.1/BootSources/Settings" }
        .to_return(status: 202, headers: { "Location" => "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_100" }, body: "{}")

      expect(client.disable_boot_entries).to eq(["Unknown.Unknown.1-1"])
      expect(patch).to have_been_requested
      expect(job).to have_been_requested
    end

    it "raises (and never POSTs the config job) when the PATCH is rejected" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(["Unknown.Unknown.1-1", true]).to_json)
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [] }.to_json)
      # authenticated_request raises IDRAC::Error on HTTP >= 400 (handle_response), so a rejected
      # PATCH aborts before the config job is scheduled -- same as the app's original path.
      stub_request(:patch, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources/Settings$})
        .to_return(status: 400, body: "bad")
      job = stub_request(:post, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs$}).to_return(status: 202, body: "{}")

      expect { client.disable_boot_entries }.to raise_error(IDRAC::Error)
      expect(job).not_to have_been_requested
    end
  end

  describe "#boot_progress" do
    it "normalizes the Redfish LastState to a snake_case symbol" do
      stub_request(:get, %r{Systems/System\.Embedded\.1\?.*BootProgress})
        .to_return(status: 200, body: { "BootProgress" => { "LastState" => "OSRunning" } }.to_json)

      expect(client.boot_progress).to eq(:os_running)
    end

    it "handles the acronym cases (PCIResourceConfigStarted)" do
      stub_request(:get, %r{Systems/System\.Embedded\.1\?.*BootProgress})
        .to_return(status: 200, body: { "BootProgress" => { "LastState" => "PCIResourceConfigStarted" } }.to_json)

      expect(client.boot_progress).to eq(:pci_resource_config_started)
    end

    it "returns nil when the BMC omits BootProgress (iDRAC8)" do
      stub_request(:get, %r{Systems/System\.Embedded\.1\?.*BootProgress})
        .to_return(status: 200, body: {}.to_json)

      expect(client.boot_progress).to be_nil
    end
  end

  describe "#drain_pending_config_jobs!" do
    it "deletes non-Completed jobs and returns their ids, keeping Completed ones" do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [
          { "Id" => "JID_1", "JobState" => "Scheduled" },
          { "Id" => "JID_2", "JobState" => "Completed" },
          { "Id" => "JID_3", "JobState" => "Running" }
        ] }.to_json)
      d1 = stub_request(:delete, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_1$}).to_return(status: 200, body: "{}")
      d3 = stub_request(:delete, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_3$}).to_return(status: 200, body: "{}")

      expect(client.drain_pending_config_jobs!).to eq(%w[JID_1 JID_3])
      expect(d1).to have_been_requested
      expect(d3).to have_been_requested
      expect(a_request(:delete, %r{/Jobs/JID_2$})).not_to have_been_requested
    end

    it "returns [] and does not raise when the queue read fails" do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 500, body: "boom")

      expect(client.drain_pending_config_jobs!).to eq([])
    end
  end

  describe "#wait_config_job" do
    it "returns the terminal state string once reached" do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_9$})
        .to_return({ status: 200, body: { "JobState" => "Running" }.to_json },
                   { status: 200, body: { "JobState" => "Completed" }.to_json })

      expect(client.wait_config_job("JID_9", interval: 0)).to eq("Completed")
    end

    it "returns nil (never raises) on timeout" do
      stub_request(:get, %r{/redfish/v1/Managers/iDRAC\.Embedded\.1/Jobs/JID_9$})
        .to_return(status: 200, body: { "JobState" => "Running" }.to_json)

      expect(client.wait_config_job("JID_9", timeout: -1)).to be_nil
    end
  end

  describe "#set_one_time_cd_boot" do
    it "drains first, then imports the ServerBoot one-time VCD SCP, and returns the import result" do
      expect(client).to receive(:drain_pending_config_jobs!).ordered.and_return([])
      expect(client).to receive(:set_system_configuration_profile).ordered do |scp, **opts|
        attrs = scp["Attributes"].each_with_object({}) { |a, h| h[a["Name"]] = a["Value"] }
        expect(scp["FQDD"]).to eq("iDRAC.Embedded.1")
        expect(attrs["ServerBoot.1#BootOnce"]).to eq("Enabled")
        expect(attrs["ServerBoot.1#FirstBootDevice"]).to eq("VCD-DVD")
        expect(opts[:target]).to eq("ALL")
        expect(opts[:reboot]).to eq(false)
        { status: :success, job_id: "JID_1", job_state: "Completed" }
      end

      expect(client.set_one_time_cd_boot[:status]).to eq(:success)
    end

    it "raises when the SCP import does not succeed" do
      allow(client).to receive(:drain_pending_config_jobs!).and_return([])
      allow(client).to receive(:set_system_configuration_profile)
        .and_return(status: :failed, job_id: "JID_1", job_state: "Failed", error: "RED097")

      expect { client.set_one_time_cd_boot }.to raise_error(IDRAC::Error, /SCP one-time vCD boot failed.*RED097/)
    end
  end
end
