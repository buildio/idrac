require 'spec_helper'
require 'idrac'
require 'webmock/rspec'

# IDRAC::Error carries the HTTP status and Dell's MessageIds as DATA. Callers deciding what to do
# about a failure (radfish-idrac recovers a 409 on the commands that schedule a config job) should
# read a fact, not match a substring of a message that no contract guarantees.
RSpec.describe IDRAC::Error do
  let(:client) do
    IDRAC::Client.new(host: 'idrac.example.com', username: 'root', password: 'calvin', verify_ssl: false)
  end

  before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)
    stub_request(:post, %r{/redfish/v1/SessionService/Sessions})
      .to_return(status: 201, headers: { 'X-Auth-Token' => 'mock-token', 'Location' => '/redfish/v1/SessionService/Sessions/1' })
  end

  describe "the attributes" do
    it "defaults to no status and no message ids, so every existing raise site still works" do
      error = described_class.new("something went wrong")
      expect(error.message).to eq("something went wrong")
      expect(error.status).to be_nil
      expect(error.message_ids).to eq([])
    end

    it "is still raisable in the `raise Error, \"...\"` form" do
      expect { raise described_class, "plain" }.to raise_error(described_class, "plain")
    end

    it "keeps the retry delay on the ServiceTemporarilyUnavailable subclass" do
      error = IDRAC::ServiceTemporarilyUnavailableError.new("busy", 30, status: 503)
      expect(error.retry_delay).to eq(30)
      expect(error.status).to eq(503)
    end
  end

  describe "raised from a failed request" do
    # The one 409 we have actually captured: us-east-1z n003, iDRAC9 (buildio/build#1974). Dell's
    # generic body. It names no job, no queue and no message id -- which is exactly why a caller
    # needs the status as data.
    it "carries the status of a 409 that explains nothing at all" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources})
        .to_return(status: 409, body: { "error" => { "message" => "A general error has occurred" } }.to_json)

      expect { client.authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootSources") }
        .to raise_error(described_class) { |e|
          expect(e.status).to eq(409)
          expect(e.message_ids).to eq([])
          expect(e.message).to include("Failed with status 409", "A general error has occurred")
        }
    end

    it "carries Dell's MessageIds when the response does explain itself" do
      body = { "error" => { "message" => "conflict",
                            "@Message.ExtendedInfo" => [
                              { "Message" => "A configuration job is already scheduled.",
                                "MessageId" => "IDRAC.2.9.LC068" }] } }
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources})
        .to_return(status: 409, body: body.to_json)

      expect { client.authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootSources") }
        .to raise_error(described_class) { |e|
          expect(e.status).to eq(409)
          expect(e.message_ids).to eq(["IDRAC.2.9.LC068"])
        }
    end

    it "leaves the message text exactly as it was, for code that rescues on it" do
      stub_request(:get, %r{/redfish/v1/Systems/System\.Embedded\.1/BootSources})
        .to_return(status: 500, body: 'not json at all')

      expect { client.authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootSources") }
        .to raise_error(described_class, /Failed with status 500 - Raw response: not json at all/) { |e|
          expect(e.status).to eq(500)
        }
    end
  end
end
