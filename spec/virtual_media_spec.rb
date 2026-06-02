require "spec_helper"

RSpec.describe IDRAC::VirtualMedia do
  # Bare consumer of just the VirtualMedia module, matching the style of the other specs.
  let(:client) { Class.new { include IDRAC::VirtualMedia }.new }

  def media_response(members)
    double(status: 200, body: { "Members" => members }.to_json)
  end

  describe "#virtual_media :inserted heuristic" do
    it "does NOT treat a stale Image string as inserted when the slot is NotConnected (iDRAC8)" do
      allow(client).to receive(:authenticated_request).and_return(
        media_response([
          { "Id" => "CD", "Name" => "Virtual CD",
            "Inserted" => false, "ConnectedVia" => "NotConnected",
            "Image" => "http://old-server/stale.iso" }
        ])
      )
      cd = client.virtual_media.find { |m| m[:device] == "CD" }
      expect(cd[:inserted]).to be(false)
    end

    it "treats a slot as inserted when the BMC reports it connected" do
      allow(client).to receive(:authenticated_request).and_return(
        media_response([
          { "Id" => "CD", "Name" => "Virtual CD",
            "Inserted" => true, "ConnectedVia" => "URI",
            "Image" => "http://server/ubuntu.iso" }
        ])
      )
      expect(client.virtual_media.first[:inserted]).to be(true)
    end

    it "falls back to the image string only when neither Inserted nor ConnectedVia is present" do
      allow(client).to receive(:authenticated_request).and_return(
        media_response([
          { "Id" => "CD", "Name" => "Virtual CD", "ImageName" => "ubuntu.iso" }
        ])
      )
      expect(client.virtual_media.first[:inserted]).to be_truthy
    end
  end

  describe "#eject_virtual_media" do
    let(:stale) do
      { "Id" => "CD", "Name" => "Virtual CD",
        "Inserted" => false, "ConnectedVia" => "NotConnected",
        "Image" => "http://old-server/stale.iso" }
    end
    let(:mounted) do
      { "Id" => "CD", "Name" => "Virtual CD",
        "Inserted" => true, "ConnectedVia" => "URI", "Image" => "http://server/x.iso" }
    end

    it "does not POST an eject for a stale-but-unmounted slot" do
      allow(client).to receive(:authenticated_request) do |method, *_|
        raise "unexpected eject POST" if method == :post
        media_response([stale])
      end
      expect(client.eject_virtual_media(device: "CD")).to be(false)
    end

    it "swallows a benign VRM0009 500 as a no-op success" do
      allow(client).to receive(:authenticated_request) do |method, *_|
        raise IDRAC::Error, "Failed with status 500: No Virtual Media devices are currently connected (IDRAC.2.9.VRM0009)" if method == :post
        media_response([mounted])
      end
      expect(client.eject_virtual_media(device: "CD")).to be(false)
    end

    it "re-raises a non-benign eject error" do
      allow(client).to receive(:authenticated_request) do |method, *_|
        raise IDRAC::Error, "Failed with status 500: Internal Server Error" if method == :post
        media_response([mounted])
      end
      expect { client.eject_virtual_media(device: "CD") }.to raise_error(IDRAC::Error, /Internal Server Error/)
    end
  end
end
