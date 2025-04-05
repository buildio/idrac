require 'json'
require 'colorize'

module IDRAC
  module Lifecycle
    # Check if the Lifecycle Controller is enabled
    def get_lifecycle_status
      # Try the standard Attributes endpoint first
      path = "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes"
      response = authenticated_request(:get, path)
      
      if response.status == 200
        begin
          attributes_data = JSON.parse(response.body)
          if attributes_data["Attributes"] && attributes_data["Attributes"]["LCAttributes.1.LifecycleControllerState"]
            lifecycle_state = attributes_data["Attributes"]["LCAttributes.1.LifecycleControllerState"]
            debug "Lifecycle Controller state (from Attributes): #{lifecycle_state}".light_cyan, 1
            return lifecycle_state == "Enabled"
          end
        rescue JSON::ParserError
          debug "Failed to parse Attributes response".yellow, 1
          # Fall through to registry method if parsing fails or attribute not found
        end
      else
        debug "Failed to get Attributes endpoint (Status: #{response.status}), trying registry method...".yellow, 1
      end
      
      # Try getting the DellAttributes for LifecycleController directly
      # The key insight is that we need to use just the base path without the fragment
      attributes_path = "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellAttributes/LifecycleController.Embedded.1"
      attributes_response = authenticated_request(:get, attributes_path)
      
      if attributes_response.status == 200
        begin
          dell_attr_data = JSON.parse(attributes_response.body)
          if dell_attr_data["Attributes"] && dell_attr_data["Attributes"]["LCAttributes.1.LifecycleControllerState"]
            lifecycle_state = dell_attr_data["Attributes"]["LCAttributes.1.LifecycleControllerState"]
            debug "Lifecycle Controller state (from Dell Attributes): #{lifecycle_state}".light_cyan, 1
            return lifecycle_state == "Enabled"
          end
        rescue JSON::ParserError
          debug "Failed to parse Dell Attributes response".yellow, 1
          # Fall through to registry method if parsing fails or attribute not found
        end
      else
        debug "Failed to get Dell Attributes (Status: #{attributes_response.status}), trying registry method...".yellow, 1
      end
      
      # Fallback to the registry method if both Attributes endpoints fail
      registry_response = authenticated_request(
        :get,
        "/redfish/v1/Registries/ManagerAttributeRegistry/ManagerAttributeRegistry.v1_0_0.json"
      )
      
      if registry_response.status != 200                                                                                               
        debug "Failed to get Lifecycle Controller Attributes Registry", 0, :red                                                             
        return false                                                                                                         
      end
      
      begin
        registry_data = JSON.parse(registry_response.body)
        # This is the attribute we want:                                                                                       
        target = registry_data['RegistryEntries']['Attributes'].find {|q| q['AttributeName'] =~ /LCAttributes.1.LifecycleControllerState/ }
        if !target
          debug "Could not find LCAttributes.1.LifecycleControllerState in registry", 0, :red
          return false
        end
        
        debug "Found attribute in registry but couldn't access it via other endpoints".yellow, 1
        return false
      rescue JSON::ParserError, NoMethodError, StandardError => e
        debug "Error during registry access: #{e.message}", 0, :red
        return false
      end
    end
    
    # Set the Lifecycle Controller status (enable/disable)
    def set_lifecycle_status(status)                                                                                   
      payload = { "Attributes": { "LCAttributes.1.LifecycleControllerState": status ? 'Enabled' : 'Disabled' } }
      response = authenticated_request(
        :patch,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellAttributes/LifecycleController.Embedded.1",
        body: payload.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      code = response.status
      case code
      when 200..299
        debug "Lifecycle Controller is now #{status ? 'Enabled' : 'Disabled'}".green, 1                                          
      when 400..499
        debug "[#{code}] This iDRAC does not support Lifecycle Controller", 0, :red                                                
      when 500..599
        debug "[#{code}] iDRAC does not support Lifecycle Controller", 0, :red                                                     
      else
      end
    end
    
    # Ensure the Lifecycle Controller is enabled
    def ensure_lifecycle_controller!
      if !get_lifecycle_status
        debug "Lifecycle Controller is disabled, enabling...".yellow, 1
        set_lifecycle_status(true)
        
        # Verify it was enabled
        if !get_lifecycle_status
          raise Error, "Failed to enable Lifecycle Controller"
        end
        
        debug "Lifecycle Controller successfully enabled".green, 1
      else
        debug "Lifecycle Controller is already enabled".green, 1
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
        debug "Lifecycle log cleared", 0, :green
        return true
      else
        debug "Failed to clear Lifecycle log", 0, :red
        
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
        debug "System Event Logs cleared", 0, :green
        return true
      else
        debug "Failed to clear System Event Logs", 0, :red
        
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
    
    # Updates the status message for the lifecycle controller
    def update_status_message(status)
      debug "Lifecycle Controller is now #{status ? 'Enabled' : 'Disabled'}".green, 1
    end
  end
end 