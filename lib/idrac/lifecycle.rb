require 'json'
require 'colorize'

module IDRAC
  module Lifecycle
    # This follows from these Scripts "GetIdracLcSystemAttributesREDFISH.py" and "SetIdracLcSystemAttributesREDFISH.py"
    # They can do more than just the lifecycle, but that's what we need right now.
    # True or False if it's enabled or not
    def get_lifecycle_status
      # Check iDRAC version first to determine the right approach
      idrac_version = get_idrac_version rescue 0
      
      debug "Detected iDRAC version: #{idrac_version}", 1
      
      # Use version-specific methods
      if idrac_version >= 9
        debug "Using modern approach for iDRAC > 9", 1
        return get_lifecycle_status_modern_firmware
      # This may have been one particularly odd oldish iDRAC 9
      # elsif idrac_version == 9
      #   debug "Using registry approach for iDRAC 9", 1
      #   return get_lifecycle_status_from_registry
      else
        debug "Using SCP approach for older iDRAC (v#{idrac_version})", 1
        return get_lifecycle_status_from_scp
      end
    end
    
    # Get lifecycle status from SCP export (for older iDRAC firmware)
    def get_lifecycle_status_from_scp
      debug "Exporting System Configuration Profile to check LifecycleController state...", 1
      
      begin
        # Use the SCP export to get LifecycleController state
        scp = get_system_configuration_profile(target: "LifecycleController")
        
        # Check if we have data in the expected format
        if scp && scp["SystemConfiguration"] && scp["SystemConfiguration"]["Components"]
          # Find the LifecycleController component
          lc_component = scp["SystemConfiguration"]["Components"].find do |component|
            component["FQDD"] == "LifecycleController.Embedded.1"
          end
          
          if lc_component && lc_component["Attributes"]
            # Find the LifecycleControllerState attribute
            lc_state_attr = lc_component["Attributes"].find do |attr|
              attr["Name"] == "LCAttributes.1#LifecycleControllerState"
            end
            
            if lc_state_attr
              debug "Found LifecycleController state from SCP: #{lc_state_attr["Value"]}", 1
              return lc_state_attr["Value"] == "Enabled"
            end
          end
        end
        
        debug "Could not find LifecycleController state in SCP export", 1, :yellow
        return false
      rescue => e
        debug "Error getting Lifecycle Controller status from SCP: #{e.message}", 1, :red
        debug e.backtrace.join("\n"), 10, :red
        return false
      end
    end
    
    # Get lifecycle status from registry (for iDRAC 9)
    def get_lifecycle_status_from_registry
      # This big JSON explains all the attributes:
      path = "/redfish/v1/Registries/ManagerAttributeRegistry/ManagerAttributeRegistry.v1_0_0.json"
      response = authenticated_request(:get, path)
      if response.status != 200
        debug "Failed to get any Lifecycle Controller Attributes".red, 1
        return false
      end
      attributes = JSON.parse(response.body)
      # This is the attribute we want:
      target = attributes&.dig('RegistryEntries', 'Attributes')&.find {|q| q['AttributeName'] =~ /LCAttributes.1.LifecycleControllerState/ }
      # This is the FQDN of the attribute we want to get the value of:
      fqdn = target.dig('Id') # LifecycleController.Embedded.1#LCAttributes.1#LifecycleControllerState
      subpath = fqdn.gsub(/#.*$/,'') # Remove everything # and onwards
      # This is the Current Value:
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellAttributes/#{subpath}")

      if response.status != 200
        debug "Failed to get Lifecycle Controller Attributes".red, 1
        return false
      end
      attributes = JSON.parse(response.body)
      # There is a ValueName and a Value Display Name (e.g. Enabled, Disabled, Recovery)
      display = attributes&.dig('Attributes','LCAttributes.1.LifecycleControllerState')
      value = target&.dig('Value')&.find { |v| v['ValueDisplayName'] == display }&.dig('ValueName')&.to_i
      value == 1
    end
    
    # Check if the Lifecycle Controller is enabled
    def get_lifecycle_status_modern_firmware
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
      path = '/redfish/v1/Managers/iDRAC.Embedded.1/Logs/Sel?$expand=*($levels=1)'
      
      response = authenticated_request(:get, path)
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)['Members'].map do |entry|
              { 
                id: entry['Id'],
                created: entry['Created'],
                message: entry['Message'],
                severity: entry['Severity']
              }
            end
          return data # RecursiveOpenStruct.new(data, recurse_over_arrays: true)
        rescue JSON::ParserError
          raise Error, "Failed to parse system event logs response: #{response.body}"
        end
      else
        raise Error, "Failed to get system event logs. Status code: #{response.status}"
      end
    end
    
    # Clear the system event logs
    def clear_system_event_logs!
      path = '/redfish/v1/Managers/iDRAC.Embedded.1/LogServices/Sel/Actions/LogService.ClearLog'
      
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
