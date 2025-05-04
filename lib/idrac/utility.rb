module IDRAC
  module Utility
    include Debuggable

    # Reset the iDRAC controller (graceful restart)
    def reset!
      debug "Resetting iDRAC controller...", 1
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset",
        body: { "ResetType" => "GracefulRestart" }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        debug "Reset command accepted, waiting for iDRAC to restart...", 1, :green
        tries = 0
        
        while true
          begin
            debug "Checking if iDRAC is back online...", 1
            response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1")
            if response.status.between?(200, 299)
              debug "iDRAC is back online!", 1, :green
              break
            end
            sleep 30
          rescue => e
            tries += 1
            if tries > 5
              debug "Failed to reconnect to iDRAC after 5 attempts", 1, :red
              return false
            end
            debug "No response from server... retry #{tries}/5", 1, :red
            sleep 2 ** tries
          end
        end
      else
        begin
          error_data = JSON.parse(response.body)
          if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
            message = error_data["error"]["@Message.ExtendedInfo"].first["Message"]
            debug "*" * 80, 1, :red
            debug message, 1, :red
            debug "*" * 80, 1, :red
          else
            debug "Failed to reset iDRAC. Status code: #{response.status}", 1, :red
          end
        rescue => e
          debug "Failed to reset iDRAC. Status code: #{response.status}", 1, :red
          debug "Error response: #{response.body}", 2, :red
        end
        return false
      end
      
      true
    end
  end
end 