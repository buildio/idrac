require 'json'
require 'colorize'

module IDRAC
  module PowerMethods
    def power_on(wait: true)
      # Login to iDRAC if needed
      login unless @session_id
      
      puts "Powering on server...".light_cyan
      
      # Check current power state first
      current_state = get_power_state rescue "Unknown"
      if current_state == "On"
        puts "Server is already powered ON.".yellow
        return false
      end
      
      # Send power on command (Reset with ResetType=On)
      path = "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
      payload = { "ResetType" => "On" }
      
      tries = 10
      while tries > 0
        response = authenticated_request(:post, path, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
        
        case response.status
        when 200, 204
          puts "Server power on command sent successfully".green
          break
        when 409
          begin
            error_data = JSON.parse(response.body)
            if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"] &&
               error_data["error"]["@Message.ExtendedInfo"].any? { |m| m["Message"] =~ /Server is already powered ON/ }
              puts "Server is already powered ON.".yellow
              return false
            else
              raise Error, "Failed to power on: #{error_data.inspect}"
            end
          rescue JSON::ParserError
            raise Error, "Failed to power on with status 409: #{response.body}"
          end
        when 500
          puts "[iDRAC 500] Server is busy...".red
          tries -= 1
          puts "Retrying... #{tries}/10".yellow if tries > 0
          sleep 10
        else
          raise Error, "Unknown response code #{response.status}: #{response.body}"
        end
      end
      
      raise Error, "Failed to power on after 10 retries" if tries <= 0
      
      # Wait for power state change if requested
      wait_for_power_state(target_state: "On", tries: 10) if wait
      
      return true
    end
    
    def power_off(wait: true, kind: "ForceOff")
      # Login to iDRAC if needed
      login unless @session_id
      
      puts "Powering off server...".light_cyan
      
      # Check current power state first
      current_state = get_power_state rescue "Unknown"
      if current_state == "Off"
        puts "Server is already powered OFF.".yellow
        return false
      end
      
      # Send power off command
      path = "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
      payload = { "ResetType" => kind }
      
      response = authenticated_request(:post, path, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
      
      case response.status
      when 200, 204
        puts "Server power off command sent successfully".green
      when 409
        # Conflict -- Server is already off
        begin
          error_data = JSON.parse(response.body)
          if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"] &&
             error_data["error"]["@Message.ExtendedInfo"].any? { |m| m["Message"] =~ /Server is already powered OFF/ }
            puts "Server is already powered OFF.".yellow
            return false
          else
            raise Error, "Failed to power off: #{error_data.inspect}"
          end
        rescue JSON::ParserError
          raise Error, "Failed to power off with status 409: #{response.body}"
        end
      else
        error_message = "Failed to power off server. Status code: #{response.status}"
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        raise Error, error_message
      end
      
      # Wait for power state change if requested
      if wait
        success = wait_for_power_state(target_state: "Off", tries: 6)
        
        # If graceful shutdown failed, try force shutdown
        if !success && kind != "ForceOff"
          return power_off(wait: wait, kind: "ForceOff")
        end
      end
      
      return true
    end
    
    def reboot
      # Login to iDRAC if needed
      login unless @session_id
      
      puts "Rebooting server...".light_cyan
      
      # Send reboot command (Reset with ResetType=ForceRestart)
      path = "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
      payload = { "ResetType" => "ForceRestart" }
      
      response = authenticated_request(:post, path, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
      
      if response.status >= 200 && response.status < 300
        puts "Server reboot command sent successfully".green
        return true
      else
        error_message = "Failed to reboot server. Status code: #{response.status}"
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
    
    def get_power_state
      # Login to iDRAC if needed
      login unless @session_id
      
      # Get system information
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$select=PowerState")
      
      if response.status == 200
        begin
          system_data = JSON.parse(response.body)
          return system_data["PowerState"]
        rescue JSON::ParserError
          raise Error, "Failed to parse power state response: #{response.body}"
        end
      else
        raise Error, "Failed to get power state. Status code: #{response.status}"
      end
    end
    
    private
    
    def wait_for_power_state(target_state:, tries: 6)
      retry_count = tries
      
      while retry_count > 0
        begin
          current_state = get_power_state
          
          return true if current_state == target_state
          
          puts "Waiting for power #{target_state == 'On' ? 'on' : 'off'}...".yellow
          puts "Current state: #{current_state}"
          retry_count -= 1
          sleep 8
        rescue => e
          puts "Error checking power state: #{e.message}".red
          retry_count -= 1
          sleep 5
        end
      end
      
      puts "Failed to reach power state #{target_state}".red
      return false
    end
  end
end 