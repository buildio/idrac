require "spec_helper"

# A restart and a shutdown are different operations with different terminal states. Conflating them
# is what powered an iDRAC8 node off and left it off: `power_off(kind: "ForceRestart")` waited for
# PowerState "Off", a restart never reports it, and the failed wait escalated to ForceOff.
RSpec.describe IDRAC::Power do
  # Every ResetType this client posted, in order. The whole defect is visible here.
  let(:posted) { [] }
  # iDRAC8's allowable values: no GracefulRestart.
  let(:power_state) { "On" }

  let(:client) do
    c = Class.new { include IDRAC::Power }.new
    allow(c).to receive(:ensure_authenticated!)
    allow(c).to receive(:get_power_state) { power_state }
    allow(c).to receive(:authenticated_request) do |_method, _path, **opts|
      posted << JSON.parse(opts[:body])["ResetType"]
      double(status: 204, body: "")
    end
    c
  end

  describe "#power_off with a restart kind" do
    it "sends the restart and never a power off" do
      client.power_off(kind: "ForceRestart", wait: false)
      expect(posted).to eq(["ForceRestart"])
    end

    # The regression itself: the host stays "On" throughout a ForceRestart, so the old wait for
    # "Off" always failed and the failure path powered the machine down for real.
    it "does not escalate to ForceOff when the host never reports Off" do
      client.power_off(kind: "ForceRestart", wait: true)
      expect(posted).to eq(["ForceRestart"])
      expect(posted).not_to include("ForceOff")
    end

    it "routes GracefulRestart to the restart action too" do
      client.power_off(kind: "GracefulRestart", wait: false)
      expect(posted).to eq(["GracefulRestart"])
    end
  end

  describe "#power_off with a shutdown kind" do
    # A shutdown that never lands still escalates — that fallback is correct for a shutdown.
    it "still escalates a stuck GracefulShutdown to ForceOff" do
      client.power_off(kind: "GracefulShutdown", wait: true)
      expect(posted).to eq(["GracefulShutdown", "ForceOff"])
    end

    it "does not escalate when it was already asked for ForceOff" do
      client.power_off(kind: "ForceOff", wait: true)
      expect(posted).to eq(["ForceOff"])
    end
  end

  describe "#reboot" do
    it "defaults to ForceRestart" do
      expect(client.reboot).to be true
      expect(posted).to eq(["ForceRestart"])
    end

    it "sends the kind it was given" do
      client.reboot(kind: "GracefulRestart")
      expect(posted).to eq(["GracefulRestart"])
    end

    # "On" is the only state a restart settles on, so waiting must not treat a host that stays On
    # as a failure.
    it "waits for On, not Off" do
      expect(client.reboot(kind: "ForceRestart", wait: true)).to be true
      expect(posted).to eq(["ForceRestart"])
    end

    context "when the host is off" do
      let(:power_state) { "Off" }

      it "powers on instead of restarting" do
        client.reboot
        expect(posted).to eq(["On"])
      end
    end
  end
end
