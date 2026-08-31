require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

RSpec.describe IDRAC::Firmware, "update slot" do
  # Each case below is a stall observed on real hardware in us-east-1z-1. All of them presented
  # as "the iDRAC is busy"; none of them were. They are Dell behaviours rather than caller
  # policy, which is why they live here rather than in a consumer.
  let(:client) do
    IDRAC::Client.new(host: 'idrac.example.com', username: 'root', password: 'calvin', verify_ssl: false)
  end
  let(:firmware) { described_class.new(client) }

  before do
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  def stub_slot(inventory_ids, jobs)
    stub_request(:get, %r{/redfish/v1/UpdateService/FirmwareInventory\z}).to_return(
      status: 200,
      body: { "Members" => inventory_ids.map { |i| { "@odata.id" => "/redfish/v1/UpdateService/FirmwareInventory/#{i}" } } }.to_json
    )
    stub_request(:get, %r{/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/Jobs}).to_return(
      status: 200,
      body: { "Members" => jobs.map { |state, pct| { "JobState" => state, "PercentComplete" => pct } } }.to_json
    )
  end

  describe "#update_slot_free?" do
    it "is free with nothing staged and no jobs" do
      stub_slot(["Installed-159-2.24.1__BIOS.Setup.1-1"], [])
      expect(firmware.update_slot_free?).to be true
    end

    it "is busy while a package is staged" do
      stub_slot(["Available-25227-7.30.30.51__iDRAC.Embedded.1-1"], [])
      expect(firmware.update_slot_free?).to be false
    end

    # The TPM ships this entry permanently. Testing for the substring "Available" matches
    # "NotAvailable", and the slot then never reads free on that machine.
    it "does not read the TPM NotAvailable entry as a staged package" do
      stub_slot(["Installed-12345-NotAvailable__TPM.Integrated.1-1"], [])
      expect(firmware.update_slot_free?).to be true
    end

    it "treats RebootCompleted as terminal" do
      stub_slot(["Installed-159-2.24.1"], [["RebootCompleted", 100]])
      expect(firmware.update_slot_free?).to be true
    end

    it "treats any state at 100 percent as terminal, including ones we have not seen" do
      stub_slot(["Installed-159-2.24.1"], [["SomeFutureDellState", 100]])
      expect(firmware.update_slot_free?).to be true
    end

    it "is busy while a job is still running" do
      stub_slot(["Installed-159-2.24.1"], [["Running", 10]])
      expect(firmware.update_slot_free?).to be false
    end
  end

  describe "#wait_for_update_slot!" do
    it "returns as soon as the slot is free" do
      allow(firmware).to receive(:update_slot_free?).and_return(true)
      expect(firmware.wait_for_update_slot!).to be true
    end

    it "raises rather than waiting forever" do
      allow(firmware).to receive(:update_slot_free?).and_return(false)
      allow(firmware).to receive(:sleep)
      expect { firmware.wait_for_update_slot!(timeout: 0) }.to raise_error(IDRAC::Error, /never freed/)
    end

    # A probe that raises must not be counted as "busy", or an unreachable BMC is
    # indistinguishable from a working one and the caller waits out the entire timeout.
    it "retries after a probe failure instead of treating it as busy" do
      calls = 0
      allow(firmware).to receive(:update_slot_free?) { calls += 1; raise IOError, "tunnel gone" if calls == 1; true }
      allow(firmware).to receive(:sleep)
      expect(firmware.wait_for_update_slot!).to be true
      expect(calls).to eq(2)
    end
  end
end
