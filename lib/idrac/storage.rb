require 'json'
require 'colorize'

module IDRAC
  module Storage
    # Get storage controllers information
    def controller
      # Use the controllers method to get all controllers
      controller_list = controllers
      
      puts "Controllers".green
      controller_list.each { |c| puts "#{c["name"]} > #{c["drives_count"]}" }
      
      puts "Drives".green
      controller_list.each do |c|
        puts "Storage: #{c["name"]} > #{c["status"]} > #{c["drives_count"]}"
      end
      
      # Find the controller with the most drives (usually the PERC)
      controller_info = controller_list.max_by { |c| c["drives_count"] }
      
      if controller_info["name"] =~ /PERC/
        puts "Found #{controller_info["name"]}".green
      else
        puts "Found #{controller_info["name"]} but continuing...".yellow
      end
      
      # Return the raw controller data
      controller_info["raw"]
    end

    # Get all storage controllers and return them as an array
    def controllers
      response = authenticated_request(:get, '/redfish/v1/Systems/System.Embedded.1/Storage?$expand=*($levels=1)')
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Transform and return all controllers as an array of hashes with string keys
          controllers = data["Members"].map do |controller|
            {
              "name" => controller["Name"],
              "model" => controller["Model"],
              "drives_count" => controller["Drives"].size,
              "status" => controller.dig("Status", "Health") || "N/A",
              "firmware_version" => controller.dig("StorageControllers", 0, "FirmwareVersion"),
              "encryption_mode" => controller.dig("Oem", "Dell", "DellController", "EncryptionMode"),
              "encryption_capability" => controller.dig("Oem", "Dell", "DellController", "EncryptionCapability"),
              "controller_type" => controller.dig("Oem", "Dell", "DellController", "ControllerType"),
              "pci_slot" => controller.dig("Oem", "Dell", "DellController", "PCISlot"),
              "raw" => controller,
              "volumes_odata_id" => controller.dig("Volumes", "@odata.id"),
              "@odata.id" => controller["@odata.id"]
            }
          end
          
          return controllers.sort_by { |c| c["name"] }
        rescue JSON::ParserError
          raise Error, "Failed to parse controllers response: #{response.body}"
        end
      else
        raise Error, "Failed to get controllers. Status code: #{response.status}"
      end
    end

    # Get information about physical drives
    def drives(controller)
      raise Error, "Controller not provided" unless controller
      
      odata_id_path = controller["@odata.id"] || controller["odata_id"]
      controller_path = odata_id_path.split("v1/").last
      response = authenticated_request(:get, "/redfish/v1/#{controller_path}?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          drives = data["Drives"].map do |body|
            serial = body["SerialNumber"] 
            serial = body["Identifiers"].first["DurableName"] if serial.blank?
            {
              "serial" => serial,
              "model" => body["Model"],
              "name" => body["Name"],
              "capacity_bytes" => body["CapacityBytes"],
              "health" => body.dig("Status", "Health") || "N/A",
              "speed_gbp" => body["CapableSpeedGbs"],
              "manufacturer" => body["Manufacturer"],
              "media_type" => body["MediaType"],
              "failure_predicted" => body["FailurePredicted"],
              "life_left_percent" => body["PredictedMediaLifeLeftPercent"],
              "certified" => body.dig("Oem", "Dell", "DellPhysicalDisk", "Certified"),
              "raid_status" => body.dig("Oem", "Dell", "DellPhysicalDisk", "RaidStatus"),
              "operation_name" => body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationName"),
              "operation_progress" => body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationPercentCompletePercent"),
              "encryption_ability" => body["EncryptionAbility"],
              "@odata.id" => body["@odata.id"]
            }
          end
          
          return drives.sort_by { |d| d["name"] }
        rescue JSON::ParserError
          raise Error, "Failed to parse drives response: #{response.body}"
        end
      else
        raise Error, "Failed to get drives. Status code: #{response.status}"
      end
    end

    # Get information about virtual disk volumes
    def volumes(controller)
      raise Error, "Controller not provided" unless controller
      
      puts "Volumes (e.g. Arrays)".green
      
      odata_id_path = controller["volumes_odata_id"]
      if odata_id_path.nil?
        raise Error, "No volumes_odata_id found in controller data. Make sure the controller is properly initialized."
      end
      response = authenticated_request(:get, "#{odata_id_path}?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          volumes = data["Members"].map do |vol|
            drives = vol["Links"]["Drives"]
            volume_data = { 
              "name" => vol["Name"], 
              "capacity_bytes" => vol["CapacityBytes"], 
              "volume_type" => vol["VolumeType"],
              "drives" => drives,
              "write_cache_policy" => vol.dig("Oem", "Dell", "DellVirtualDisk", "WriteCachePolicy"),
              "read_cache_policy" => vol.dig("Oem", "Dell", "DellVirtualDisk", "ReadCachePolicy"),
              "stripe_size" => vol.dig("Oem", "Dell", "DellVirtualDisk", "StripeSize"),
              "raid_level" => vol["RAIDType"],
              "encrypted" => vol["Encrypted"],
              "lock_status" => vol.dig("Oem", "Dell", "DellVirtualDisk", "LockStatus"),
              "@odata.id" => vol["@odata.id"]
            }
            
            # Check FastPath settings
            volume_data["fastpath"] = fastpath_good?(volume_data)
            
            # Handle volume operations and status
            if vol["Operations"].any?
              volume_data["health"] = vol.dig("Status", "Health") || "N/A"
              volume_data["progress"] = vol["Operations"].first["PercentageComplete"]
              volume_data["message"] = vol["Operations"].first["OperationName"]     
            elsif vol.dig("Status", "Health") == "OK"
              volume_data["health"] = "OK"
              volume_data["progress"] = nil
              volume_data["message"] = nil
            else
              volume_data["health"] = "?"
              volume_data["progress"] = nil
              volume_data["message"] = nil
            end
            
            # Return the hash directly
            volume_data
          end
          
          return volumes.sort_by { |d| d["name"] }
        rescue JSON::ParserError
          raise Error, "Failed to parse volumes response: #{response.body}"
        end
      else
        raise Error, "Failed to get volumes. Status code: #{response.status}"
      end
    end

    # Check if FastPath is properly configured for a volume
    def fastpath_good?(volume)
      return "disabled" unless volume
      
      # Modern firmware check handled by caller
      if volume["write_cache_policy"] == "WriteThrough" && 
         volume["read_cache_policy"] == "NoReadAhead" && 
         volume["stripe_size"] == "64KB"
        return "enabled"
      else
        return "disabled"
      end
    end

    # Delete a volume
    def delete_volume(odata_id)
      path = odata_id.split("v1/").last
      puts "Deleting volume: #{path}"
      
      response = authenticated_request(:delete, "/redfish/v1/#{path}")
      
      if response.status.between?(200, 299)
        puts "Delete volume request sent".green
        
        # Check if we need to wait for a job
        if response.headers["location"]
          job_id = response.headers["location"].split("/").last
          wait_for_job(job_id)
        end
        
        return true
      else
        error_message = "Failed to delete volume. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end

    # Create a new virtual disk with RAID5 and FastPath optimizations
    def create_virtual_disk(controller_id, drives, name: "vssd0", raid_type: "RAID5")
      # Check firmware version to determine which API to use
      firmware_version = get_firmware_version.split(".")[0,2].join.to_i
      
      # [FastPath optimization for SSDs](https://www.dell.com/support/manuals/en-us/perc-h755/perc11_ug/fastpath?guid=guid-a9e90946-a41f-48ab-88f1-9ce514b4c414&lang=en-us)
      payload = {
        "Drives": drives.map { |d| { "@odata.id": d["@odata.id"] } },
        "Name": name,
        "OptimumIOSizeBytes": 64 * 1024,
        "Oem": { "Dell": { "DellVolume": { "DiskCachePolicy": "Enabled" } } },
        "ReadCachePolicy": "Off", # "NoReadAhead"
        "WriteCachePolicy": "WriteThrough"
      }
      
      # If the firmware < 440, we need a different approach
      if firmware_version >= 440
        # For modern firmware
        if drives.size < 3 && raid_type == "RAID5"
          puts "*************************************************".red
          puts "* WARNING: Less than 3 drives. Selecting RAID0. *".red
          puts "*************************************************".red
          payload["RAIDType"] = "RAID0"
        else
          payload["RAIDType"] = raid_type
        end
      else
        # For older firmware
        payload["VolumeType"] = "StripedWithParity" if raid_type == "RAID5"
        payload["VolumeType"] = "SpannedDisks" if raid_type == "RAID0"
      end
      
      url = "Systems/System.Embedded.1/Storage/#{controller_id}/Volumes"
      response = authenticated_request(
        :post, 
        "/redfish/v1/#{url}", 
        body: payload.to_json, 
        headers: { 'Content-Type': 'application/json' }
      )
      
      if response.status.between?(200, 299)
        puts "Virtual disk creation started".green
        
        # Check if we need to wait for a job
        if response.headers["location"]
          job_id = response.headers["location"].split("/").last
          wait_for_job(job_id)
        end
        
        return true
      else
        error_message = "Failed to create virtual disk. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end

    # Enable Self-Encrypting Drive support on controller
    def enable_local_key_management(controller_id, passphrase: "Secure123!", keyid: "RAID-Key-2023")
      payload = { 
        "TargetFQDD": controller_id, 
        "Key": passphrase, 
        "Keyid": keyid 
      }
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Dell/Systems/System.Embedded.1/DellRaidService/Actions/DellRaidService.SetControllerKey",
        body: payload.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      if response.status == 202
        puts "Controller encryption enabled".green
        
        # Check if we need to wait for a job
        if response.headers["location"]
          job_id = response.headers["location"].split("/").last
          wait_for_job(job_id)
        end
        
        return true
      else
        error_message = "Failed to enable controller encryption. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end

    # Disable Self-Encrypting Drive support on controller
    def disable_local_key_management(controller_id)
      payload = { "TargetFQDD": controller_id }
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Dell/Systems/System.Embedded.1/DellRaidService/Actions/DellRaidService.RemoveControllerKey",
        body: payload.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      if response.status == 202
        puts "Controller encryption disabled".green
        
        # Check if we need to wait for a job
        if response.headers["location"]
          job_id = response.headers["location"].split("/").last
          wait_for_job(job_id)
        end
        
        return true
      else
        error_message = "Failed to disable controller encryption. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end

    # Check if all physical disks are Self-Encrypting Drives
    def all_seds?(drives)
      drives.all? { |d| d["encryption_ability"] == "SelfEncryptingDrive" }
    end

    # Check if the system is ready for SED operations
    def sed_ready?(controller, drives)
      all_seds?(drives) && controller_encryption_capable?(controller) && controller_encryption_enabled?(controller)
    end

    # Get firmware version
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

    # Check if the controller is capable of encryption
    def controller_encryption_capable?(controller)
      controller.dig("encryption_capability") =~ /localkey/i
    end

    # Check if controller encryption is enabled
    def controller_encryption_enabled?(controller)
      controller.dig("encryption_mode") =~ /localkey/i
    end
  end
end