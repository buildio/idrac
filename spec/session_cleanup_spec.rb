require 'spec_helper'

RSpec.describe "Session Cleanup" do
  let(:client) { IDRAC::Client.new(host: "192.168.1.100", username: "root", password: "calvin") }

  describe "automatic session management" do
    it "always attempts to clear sessions when maxed out" do
      # Session management is now always automatic - no longer configurable
      expect(client.session).to respond_to(:force_clear_sessions)
      expect(client.session).to respond_to(:delete_all_sessions_with_basic_auth)
    end
    
    it "does not expose auto_delete_sessions parameter" do
      # The auto_delete_sessions parameter has been removed
      expect(client).not_to respond_to(:auto_delete_sessions)
      expect(client.session).not_to respond_to(:auto_delete_sessions)
    end
  end

  describe "finalizer registration" do
    it "has a finalizer class method" do
      # The finalizer method should be available on the Client class
      expect(IDRAC::Client).to respond_to(:finalizer)
      
      # It should return a proc when called with session and web objects
      mock_session = double("Session")
      mock_web = double("Web")
      finalizer_proc = IDRAC::Client.finalizer(mock_session, mock_web)
      expect(finalizer_proc).to be_a(Proc)
    end
  end

  describe "block-based API" do
    it "provides a connect method on Client class" do
      expect(IDRAC::Client).to respond_to(:connect)
    end

    it "provides a connect method on IDRAC module" do
      expect(IDRAC).to respond_to(:connect)
    end

    it "calls login and logout when using block syntax" do
      mock_client = double("Client")
      allow(IDRAC::Client).to receive(:new).and_return(mock_client)
      expect(mock_client).to receive(:login)
      expect(mock_client).to receive(:logout)

      IDRAC::Client.connect(host: "test", username: "user", password: "pass") do |client|
        # Block content
      end
    end

    it "ensures logout is called even when exception occurs" do
      mock_client = double("Client")
      allow(IDRAC::Client).to receive(:new).and_return(mock_client)
      expect(mock_client).to receive(:login)
      expect(mock_client).to receive(:logout)

      expect {
        IDRAC::Client.connect(host: "test", username: "user", password: "pass") do |client|
          raise "test error"
        end
      }.to raise_error("test error")
    end

    it "returns client without block when no block given" do
      result = IDRAC::Client.connect(host: "test", username: "user", password: "pass")
      expect(result).to be_an_instance_of(IDRAC::Client)
    end
  end

  describe "session management methods" do
    it "has logout method" do
      expect(client).to respond_to(:logout)
    end

    it "has session with delete method" do
      expect(client.session).to respond_to(:delete)
    end

    it "has force_clear_sessions method" do
      expect(client.session).to respond_to(:force_clear_sessions)
    end
  end
end 