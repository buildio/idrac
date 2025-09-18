module IDRAC
  class Error < StandardError; end
  
  class ServiceTemporarilyUnavailableError < Error
    attr_reader :retry_delay
    
    def initialize(message, retry_delay)
      super(message)
      @retry_delay = retry_delay
    end
  end
end 