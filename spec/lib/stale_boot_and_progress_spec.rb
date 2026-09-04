require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

# Covers the raw-Redfish boot mechanics the app used to hand-roll in server.rb
# (neutralize_stale_boot_entries! / wait_for_bios_config_job! / os_running?).
RSpec.describe "IDRAC::Boot stale entries and boot progress" do
  let(:client) do
    IDRAC::Client.new(host: 'idrac.example.com', username: 'root', password: 'calvin', verify_ssl: false)
  end

  before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  def boot_sources(*names_enabled)
    seq = names_enabled.each_with_index.map do |(name, enabled), i|
      { "Id" => "Boot%04d" % i, "Index" => i, "Name" => name, "Enabled" => enabled }
    end
    { "Attributes" => { "UefiBootSeq" => seq } }
  end

  describe "#stale_uefi_boot_entries" do
    it "returns only the still-enabled Unknown.Unknown.* placeholders" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(
          ["Unknown.Unknown.1-1", true], ["NIC.PxeDevice.1-1", true],
          ["Unknown.Unknown.2-1", false], ["RAID.Integrated.1-1", true]).to_json)

      names = client.stale_uefi_boot_entries.map { |e| e["Name"] }
      expect(names).to eq(["Unknown.Unknown.1-1"])
    end

    it "returns [] when not in UEFI mode / no BootSources" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: { "Attributes" => {} }.to_json)
      expect(client.stale_uefi_boot_entries).to eq([])
    end
  end

  describe "#disable_boot_entries" do
    before do
      # drain: no pending jobs to clear
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [] }.to_json)
      # config job POST returns a JID in the Location header
      stub_request(:post, %r{/Managers/iDRAC\.Embedded\.1/Jobs$})
        .to_return(status: 202, headers: { 'Location' => '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_555' }, body: '')
      # the config job completes
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs/JID_555})
        .to_return(status: 200, body: { "JobState" => "Completed", "Message" => "Done" }.to_json)
    end

    it "disables the matched entries, PATCHing Enabled=false, and returns their names" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(
          ["Unknown.Unknown.1-1", true], ["NIC.PxeDevice.1-1", true], ["RAID.Integrated.1-1", true]).to_json)

      patched = nil
      stub_request(:patch, %r{/Systems/System\.Embedded\.1/BootSources/Settings$})
        .to_return { |req| patched = JSON.parse(req.body); { status: 200, body: '{}' } }

      result = client.disable_boot_entries

      expect(result).to eq(["Unknown.Unknown.1-1"])
      seq = patched.dig("Attributes", "UefiBootSeq")
      expect(seq.find { |e| e["Name"] == "Unknown.Unknown.1-1" }["Enabled"]).to eq(false)
      expect(seq.find { |e| e["Name"] == "RAID.Integrated.1-1" }["Enabled"]).to eq(true)
    end

    it "is a no-op (no PATCH, no job) when nothing matches" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(["RAID.Integrated.1-1", true]).to_json)

      expect(client.disable_boot_entries).to eq([])
      expect(a_request(:patch, %r{/BootSources/Settings})).not_to have_been_made
      expect(a_request(:post, %r{/Managers/iDRAC\.Embedded\.1/Jobs$})).not_to have_been_made
    end

    it "drains a pending LC job before scheduling its own (LC068 self-heal)" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1/BootSources$})
        .to_return(status: 200, body: boot_sources(["Unknown.Unknown.1-1", true]).to_json)
      stub_request(:patch, %r{/Systems/System\.Embedded\.1/BootSources/Settings$}).to_return(status: 200, body: '{}')
      # a stale scheduled job is present, then a delete clears it
      stub_request(:get, %r{/Managers/iDRAC\.Embedded\.1/Jobs\?})
        .to_return(status: 200, body: { "Members" => [{ "Id" => "JID_OLD", "JobState" => "Scheduled" }] }.to_json)
      del = stub_request(:delete, %r{/Managers/iDRAC\.Embedded\.1/Jobs/JID_OLD}).to_return(status: 200, body: '{}')

      client.disable_boot_entries
      expect(del).to have_been_made
    end
  end

  describe "#boot_progress" do
    it "returns a normalized snake_case symbol for the Redfish LastState" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1\?\$select=BootProgress})
        .to_return(status: 200, body: { "BootProgress" => { "LastState" => "OSRunning" } }.to_json)
      expect(client.boot_progress).to eq(:os_running)
    end

    it "returns nil when the BMC omits BootProgress (iDRAC8)" do
      stub_request(:get, %r{/Systems/System\.Embedded\.1\?\$select=BootProgress})
        .to_return(status: 200, body: { "Model" => "PowerEdge R630" }.to_json)
      expect(client.boot_progress).to be_nil
    end
  end

  describe "#normalize_boot_progress" do
    it "maps the Redfish enum to snake_case symbols" do
      expect(client.normalize_boot_progress("OSRunning")).to eq(:os_running)
      expect(client.normalize_boot_progress("OSBootStarted")).to eq(:os_boot_started)
      expect(client.normalize_boot_progress("SetupEntered")).to eq(:setup_entered)
      expect(client.normalize_boot_progress("None")).to eq(:none)
      expect(client.normalize_boot_progress(nil)).to be_nil
    end
  end
end
