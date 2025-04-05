require 'json'
require 'colorize'

module IDRAC
  module VirtualMediaMethods
    # Get current virtual media status
    def virtual_media
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          media = data["Members"].map do |m|
            if m["Inserted"]
              puts "#{m["Name"]} #{m["ConnectedVia"]} #{m["Image"]}".green
            else
              puts "#{m["Name"]} #{m["ConnectedVia"]}".yellow
            end
            
            action_path = m.dig("Actions", "#VirtualMedia.InsertMedia", "target")
            
            { 
              device: m["Id"], 
              inserted: m["Inserted"], 
              image: m["Image"] || m["ConnectedVia"],
              action_path: action_path
            }
          end
          
          return media
        rescue JSON::ParserError
          raise Error, "Failed to parse virtual media response: #{response.body}"
        end
      else
        raise Error, "Failed to get virtual media. Status code: #{response.status}"
      end
    end

    # Eject virtual media from a device
    def eject_virtual_media(device: "CD")
      media_list = virtual_media
      
      # Find the device to eject
      media_to_eject = media_list.find { |m| m[:device] == device && m[:inserted] }
      
      if media_to_eject.nil?
        puts "No media #{device} to eject".yellow
        return false
      end
      
      puts "Ejecting #{media_to_eject[:device]} #{media_to_eject[:image]}".yellow
      
      # Use the action path from the media object if available
      path = if media_to_eject[:action_path]
              media_to_eject[:action_path].sub(/^\/redfish\/v1\//, "").sub(/InsertMedia$/, "EjectMedia")
             else
              "Managers/iDRAC.Embedded.1/VirtualMedia/#{device}/Actions/VirtualMedia.EjectMedia"
             end
      
      response = authenticated_request(
        :post, 
        "/redfish/v1/#{path}",
        body: {}.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      case response.status
      when 200..299
        sleep 5 # Wait for ejection to complete
        puts "Ejected #{media_to_eject[:device]}".green
        return true
      when 500..599
        # Check if the error is "No Virtual Media devices are currently connected"
        begin
          error_data = JSON.parse(response.body)
          if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"] &&
             error_data["error"]["@Message.ExtendedInfo"].any? { |m| m["Message"] =~ /No Virtual Media devices are currently connected/ }
            puts "No Virtual Media devices are currently connected".yellow
            return false
          end
        rescue JSON::ParserError
          # Ignore parsing errors
        end
        
        puts "Failed to eject media: #{response.status}".red
        return false
      else
        puts "Unexpected response code: #{response.status}".red
        return false
      end
    end

    # Insert virtual media (ISO)
    def insert_virtual_media(iso_url, device: "CD")
      raise Error, "Device must be CD or RemovableDisk" unless ["CD", "RemovableDisk"].include?(device)
      
      # First eject any inserted media
      eject_virtual_media(device: device)
      
      # Firmware version determines which API to use
      firmware_version = get_firmware_version.split(".")[0,2].join.to_i
      
      puts "Inserting media: #{iso_url}".yellow
      
      tries = 0
      max_tries = 10
      
      while tries < max_tries
        begin
          # Different endpoint based on firmware version
          path = if firmware_version >= 600
                  "Systems/System.Embedded.1/VirtualMedia/1/Actions/VirtualMedia.InsertMedia" 
                 else
                  "Managers/iDRAC.Embedded.1/VirtualMedia/#{device}/Actions/VirtualMedia.InsertMedia"
                 end
          
          response = authenticated_request(
            :post, 
            "/redfish/v1/#{path}",
            body: { "Image": iso_url, "Inserted": true, "WriteProtected": true }.to_json,
            headers: { 'Content-Type': 'application/json' }
          )
          
          if response.status == 204 || response.status == 200
            puts "Inserted media successfully".green
            return true
          end
          
          # Handle error responses
          error_message = "Failed to insert media. Status code: #{response.status}"
          begin
            error_data = JSON.parse(response.body)
            if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
              error_info = error_data["error"]["@Message.ExtendedInfo"].first
              error_message += ", Message: #{error_info['Message']}"
            end
          rescue
            # Ignore JSON parsing errors
          end
          
          puts "#{error_message}. Retrying (#{tries + 1}/#{max_tries})...".red
        rescue => e
          puts "Error during insert_virtual_media: #{e.message}. Retrying (#{tries + 1}/#{max_tries})...".red
        end
        
        tries += 1
        sleep 60 # Wait before retry
      end
      
      raise Error, "Failed to insert virtual media after #{max_tries} attempts"
    end

    # Set boot to virtual media once, then boot from HD
    def set_one_time_virtual_media_boot
      # Check firmware version to determine which API to use
      firmware_version = get_firmware_version.split(".")[0,2].join.to_i
      
      if firmware_version >= 440 # Modern iDRAC
        # Check current boot configuration
        boot_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
        if boot_response.status == 200
          boot_data = JSON.parse(boot_response.body)
          enabled = boot_data['Boot']['BootSourceOverrideEnabled']
          target = boot_data['Boot']['BootSourceOverrideTarget']
          puts "Currently override is #{enabled} to boot from #{target}".yellow
        end
        
        # Set one-time boot to CD
        response = authenticated_request(
          :patch, 
          "/redfish/v1/Systems/System.Embedded.1",
          body: { "Boot": { "BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once" } }.to_json,
          headers: { 'Content-Type': 'application/json' }
        )
        
        if response.status.between?(200, 299)
          puts "One-time boot to virtual media configured".green
          return true
        else
          error_message = "Failed to set one-time boot. Status code: #{response.status}"
          begin
            error_data = JSON.parse(response.body)
            if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
              error_info = error_data["error"]["@Message.ExtendedInfo"].first
              error_message += ", Message: #{error_info['Message']}"
            end
          rescue
            # Ignore JSON parsing errors
          end
          
          raise Error, error_message
        end
      else
        # For older iDRAC, we need to use the iDRAC-specific method
        payload = { 
          "ServerBoot.1#BootOnce": "Enabled",
          "ServerBoot.1#FirstBootDevice": "VCD-DVD"
        }
        
        response = authenticated_request(
          :patch, 
          "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes",
          body: payload.to_json,
          headers: { 'Content-Type': 'application/json' }
        )
        
        if response.status.between?(200, 299)
          puts "One-time boot to virtual media configured".green
          return true
        else
          error_message = "Failed to set one-time boot. Status code: #{response.status}"
          begin
            error_data = JSON.parse(response.body)
            if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
              error_info = error_data["error"]["@Message.ExtendedInfo"].first
              error_message += ", Message: #{error_info['Message']}"
            end
          rescue
            # Ignore JSON parsing errors
          end
          
          raise Error, error_message
        end
      end
    end

    # Get current boot source override settings
    def get_boot_source_override
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          boot = data["Boot"]
          
          puts "Boot Source Override Configuration:".green
          puts "  Enabled: #{boot['BootSourceOverrideEnabled']}"
          puts "  Target: #{boot['BootSourceOverrideTarget']}"
          puts "  Mode: #{boot['BootSourceOverrideMode']}" if boot['BootSourceOverrideMode']
          
          if boot["BootSourceOverrideEnabled"] != "Once" || boot["BootSourceOverrideTarget"] == "None"
            return "None"
          else
            return "#{boot['BootSourceOverrideMode']} #{boot['BootSourceOverrideTarget']}"
          end
        rescue JSON::ParserError
          raise Error, "Failed to parse boot source response: #{response.body}"
        end
      else
        raise Error, "Failed to get boot source override. Status code: #{response.status}"
      end
    end

    private

    # Get firmware version (helper method for virtual media operations)
    def get_firmware_version
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1?$select=FirmwareVersion")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          return data["FirmwareVersion"]
        rescue JSON::ParserError
          raise Error, "Failed to parse firmware version response: #{response.body}"
        end
      else
        # Try again without the $select parameter for older firmware
        response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1")
        
        if response.status == 200
          begin
            data = JSON.parse(response.body)
            return data["FirmwareVersion"]
          rescue JSON::ParserError
            raise Error, "Failed to parse firmware version response: #{response.body}"
          end
        else
          raise Error, "Failed to get firmware version. Status code: #{response.status}"
        end
      end
    end
  end
end 