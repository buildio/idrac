require 'json'
require 'colorize'

module IDRAC
  module LifecycleMethods
    # Get the Lifecycle Controller status
    def get_lifecycle_status
      # Try first method (older iDRACs)
      path1 = '/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.GetRemoteServicesAPIStatus'
      
      begin
        response = authenticated_request(
          :post, 
          path1, 
          body: {}.to_json, 
          headers: { 'Content-Type' => 'application/json' }
        )
        
        if response.status.between?(200, 299)
          begin
            lc_data = JSON.parse(response.body)
            puts "LC Status: #{lc_data['LCStatus']}".light_cyan
            return lc_data
          rescue JSON::ParserError
            # Fall through to alternative method
          end
        end
      rescue => e
        # Fall through to alternative method
      end
      
      # Try alternative method (newer iDRACs)
      path2 = '/redfish/v1/Managers/iDRAC.Embedded.1/Attributes'
      
      begin
        response = authenticated_request(:get, path2)
        
        if response.status.between?(200, 299)
          begin
            attributes_data = JSON.parse(response.body)
            
            if attributes_data["Attributes"] && attributes_data["Attributes"]["LCAttributes.1.LifecycleControllerState"]
              lifecycle_state = attributes_data["Attributes"]["LCAttributes.1.LifecycleControllerState"]
              puts "Lifecycle Controller state: #{lifecycle_state}".light_cyan
              return { "LCStatus" => lifecycle_state }
            end
          rescue JSON::ParserError
            # Fall through to final error
          end
        end
      rescue => e
        # Fall through to final error
      end

      # If we get here, try one last approach - try to get iDRAC status
      begin
        response = authenticated_request(:get, '/redfish/v1/Managers/iDRAC.Embedded.1')
        
        if response.status.between?(200, 299)
          begin
            data = JSON.parse(response.body)
            status = data["Status"] && data["Status"]["State"]
            if status
              puts "iDRAC State: #{status}".light_cyan
              puts "Note: Could not retrieve direct LC status, showing iDRAC status instead".yellow
              return { "iDRACStatus" => status }
            end
          rescue JSON::ParserError
            # Fall through to final error
          end
        end
      rescue => e
        # Fall through to final error
      end

      # If we reached here, all methods failed
      puts "Unable to retrieve Lifecycle Controller status through any available method".red
      raise Error, "Failed to get Lifecycle Controller status through any available method"
    end
    
    # Check if the Lifecycle Controller is enabled
    def get_idrac_lifecycle_status
      # Use the DellLCService GetRemoteServicesAPIStatus
      path = '/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.GetRemoteServicesAPIStatus'
      
      response = authenticated_request(
        :post, 
        path, 
        body: {}.to_json, 
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        begin
          lc_data = JSON.parse(response.body)
          status = lc_data["LCStatus"]
          
          debug "LC Status: #{status}", 1
          
          # Get the LCReplication status
          attributes_path = "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes"
          attributes_response = authenticated_request(:get, attributes_path)
          
          if attributes_response.status == 200
            begin
              attributes_data = JSON.parse(attributes_response.body)
              lc_replication = attributes_data["Attributes"]["ServiceModule.1.LCLReplication"]
              
              debug "ServiceModule.1.LCLReplication: #{lc_replication}", 1
              
              is_enabled = lc_replication == "Enabled"
              
              puts "Lifecycle Controller replication is #{is_enabled ? 'enabled' : 'disabled'}".light_cyan
              puts "Lifecycle Controller status: #{status}".light_cyan
              return is_enabled
            rescue => e
              debug "Error parsing attributes: #{e.message}", 1
            end
          end
          
          # If we can't determine from attributes, just return if LC is Ready
          is_ready = status == "Ready"
          puts "Lifecycle Controller is #{is_ready ? 'Ready' : status}".light_cyan
          return is_ready
        rescue JSON::ParserError
          raise Error, "Failed to parse Lifecycle Controller status response: #{response.body}"
        end
      else
        raise Error, "Failed to get Lifecycle Controller status. Status code: #{response.status}"
      end
    end
    
    # Set the Lifecycle Controller status (enable/disable)
    def set_idrac_lifecycle_status(status)
      enabled = !!status # Convert to boolean
      
      debug "Setting Lifecycle Controller status to #{enabled ? 'enabled' : 'disabled'}", 1
      
      # Use the attributes method to set the ServiceModule.1.LCLReplication
      path = "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes"
      
      # Create the payload with the attribute we want to modify
      payload = {
        "Attributes": {
          "ServiceModule.1.LCLReplication": enabled ? "Enabled" : "Disabled"
        }
      }
      
      debug "Using attributes endpoint: #{path}", 1
      debug "Payload: #{payload.inspect}", 1
      
      begin
        response = authenticated_request(
          :patch, 
          path, 
          body: payload.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
        
        debug "Response status: #{response.status}", 1
        debug "Response body: #{response.body}", 2 if response.body
        
        if response.status.between?(200, 299)
          puts "Successfully #{enabled ? 'enabled' : 'disabled'} Lifecycle Controller".green
          return true
        else
          error_message = "Failed to set Lifecycle Controller status. Status code: #{response.status}"
          
          # Print the full response body for debugging
          puts "Full error response body:".red
          puts response.body.inspect.red
          
          begin
            error_data = JSON.parse(response.body)
            puts "Extended error information:".red if error_data['@Message.ExtendedInfo']
            
            if error_data['error'] && error_data['error']['message']
              error_message += ", Message: #{error_data['error']['message']}"
            end
            
            if error_data['@Message.ExtendedInfo']
              error_data['@Message.ExtendedInfo'].each do |info|
                puts "  Message: #{info['Message']}".red
                puts "  Resolution: #{info['Resolution']}".yellow if info['Resolution']
                puts "  Severity: #{info['Severity']}".yellow if info['Severity']
                puts "  MessageId: #{info['MessageId']}".yellow if info['MessageId']
              end
              
              if error_data['@Message.ExtendedInfo'].first
                error_message += ", Message: #{error_data['@Message.ExtendedInfo'].first['Message']}"
                error_message += ", Resolution: #{error_data['@Message.ExtendedInfo'].first['Resolution']}" if error_data['@Message.ExtendedInfo'].first['Resolution']
              end
            end
          rescue => e
            debug "Error parsing response: #{e.message}", 1
            # Ignore JSON parsing errors
          end
          
          raise Error, error_message
        end
      rescue => e
        debug "Error in request: #{e.message}", 1
        raise Error, "Failed to set Lifecycle Controller status: #{e.message}"
      end
    end
    
    # Ensure the Lifecycle Controller is enabled
    def ensure_lifecycle_controller!
      if !get_idrac_lifecycle_status
        puts "Lifecycle Controller is disabled, enabling...".yellow
        set_idrac_lifecycle_status(true)
        
        # Verify it was enabled
        if !get_idrac_lifecycle_status
          raise Error, "Failed to enable Lifecycle Controller"
        end
        
        puts "Lifecycle Controller successfully enabled".green
      else
        puts "Lifecycle Controller is already enabled".green
      end
      
      return true
    end
    
    # Clear the Lifecycle log
    def clear_lifecycle!
      path = '/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLCService/Actions/DellLCService.SystemErase'
      payload = { "Component": ["LCData"] }
      
      response = authenticated_request(
        :post, 
        path, 
        body: payload.to_json, 
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        puts "Lifecycle log cleared".green
        return true
      else
        puts "Failed to clear Lifecycle log".red
        
        error_message = "Failed to clear Lifecycle log. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
    
    # Get the system event logs
    def get_system_event_logs
      path = 'Managers/iDRAC.Embedded.1/Logs/Sel?$expand=*($levels=1)'
      
      response = authenticated_request(:get, path)
      
      if response.status == 200
        begin
          logs_data = JSON.parse(response.body)
          return logs_data
        rescue JSON::ParserError
          raise Error, "Failed to parse system event logs response: #{response.body}"
        end
      else
        raise Error, "Failed to get system event logs. Status code: #{response.status}"
      end
    end
    
    # Clear the system event logs
    def clear_system_event_logs!
      path = 'Managers/iDRAC.Embedded.1/LogServices/Sel/Actions/LogService.ClearLog'
      
      response = authenticated_request(:post, path, body: {}.to_json, headers: { 'Content-Type' => 'application/json' })
      
      if response.status.between?(200, 299)
        puts "System Event Logs cleared".green
        return true
      else
        puts "Failed to clear System Event Logs".red
        
        error_message = "Failed to clear System Event Logs. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
  end
end 