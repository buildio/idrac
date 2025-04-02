require 'json'
require 'colorize'

module IDRAC
  class Power
    attr_reader :client
    
    def initialize(client)
      @client = client
    end
    
    def power_on
      # Ensure we have a client
      raise Error, "Client is required for power management" unless client
      
      # Login to iDRAC if needed
      client.login unless client.instance_variable_get(:@session_id)
      
      puts "Powering on server...".light_cyan
      
      # Send power on command (Reset with ResetType=On)
      path = "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
      payload = { "ResetType" => "On" }
      
      response = client.authenticated_request(:post, path, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
      
      if response.status >= 200 && response.status < 300
        puts "Server power on command sent successfully".green
        return true
      else
        error_message = "Failed to power on server. Status code: #{response.status}"
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
    
    def power_off
      # Ensure we have a client
      raise Error, "Client is required for power management" unless client
      
      # Login to iDRAC if needed
      client.login unless client.instance_variable_get(:@session_id)
      
      puts "Powering off server...".light_cyan
      
      # Send power off command (Reset with ResetType=ForceOff)
      path = "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
      payload = { "ResetType" => "ForceOff" }
      
      response = client.authenticated_request(:post, path, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
      
      if response.status >= 200 && response.status < 300
        puts "Server power off command sent successfully".green
        return true
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
    end
    
    def reboot
      # Ensure we have a client
      raise Error, "Client is required for power management" unless client
      
      # Login to iDRAC if needed
      client.login unless client.instance_variable_get(:@session_id)
      
      puts "Rebooting server...".light_cyan
      
      # Send reboot command (Reset with ResetType=ForceRestart)
      path = "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
      payload = { "ResetType" => "ForceRestart" }
      
      response = client.authenticated_request(:post, path, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
      
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
      # Ensure we have a client
      raise Error, "Client is required for power management" unless client
      
      # Login to iDRAC if needed
      client.login unless client.instance_variable_get(:@session_id)
      
      # Get system information
      response = client.authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if response.status == 200
        system_data = JSON.parse(response.body)
        return system_data["PowerState"]
      else
        raise Error, "Failed to get power state. Status code: #{response.status}"
      end
    end
  end
end 