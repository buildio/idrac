module IDRAC
  # The HTTP status and Dell's MessageIds are read off the response where the error is raised, and
  # kept HERE as data. The message text is unchanged -- this is purely additive, and code that
  # rescues on the message (see the VRM0009 check in virtual_media.rb) is unaffected -- but a caller
  # that needs to know WHAT happened no longer has to parse prose. A reworded message breaks a
  # substring match silently; a status is a fact.
  #
  # Both default to nil/[], so every `raise Error, "..."` site keeps working unchanged and an error
  # raised anywhere but handle_response simply reports no status.
  class Error < StandardError
    attr_reader :status, :message_ids

    def initialize(message = nil, status: nil, message_ids: [])
      super(message)
      @status = status
      @message_ids = Array(message_ids)
    end
  end

  class ServiceTemporarilyUnavailableError < Error
    attr_reader :retry_delay

    def initialize(message, retry_delay, status: nil, message_ids: [])
      super(message, status: status, message_ids: message_ids)
      @retry_delay = retry_delay
    end
  end
end 