require 'json'
require 'colorize'

module IDRAC
  module Storage
    # Get all storage controllers and return them as an array
    def controllers
      response = authenticated_request(:get, '/redfish/v1/Systems/System.Embedded.1/Storage?$expand=*($levels=1)')
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Transform and return all controllers as an array of hashes with string keys
          controllers = data["Members"].map do |controller|
            controller_data = {
              "id" => controller["Id"],
              "name" => controller["Name"],
              "model" => controller["Model"],
              "drives_count" => controller["Drives"].size,
              "status" => controller.dig("Status", "Health") || "N/A",
              "firmware_version" => controller.dig("StorageControllers", 0, "FirmwareVersion"),
              "encryption_mode" => controller.dig("Oem", "Dell", "DellController", "EncryptionMode"),
              "encryption_capability" => controller.dig("Oem", "Dell", "DellController", "EncryptionCapability"),
              "controller_type" => controller.dig("Oem", "Dell", "DellController", "ControllerType"),
              "pci_slot" => controller.dig("Oem", "Dell", "DellController", "PCISlot"),
              "@odata.id" => controller["@odata.id"],
              # Store full controller data for access to all fields
              "Oem" => controller["Oem"],
              "Status" => controller["Status"],
              "StorageControllers" => controller["StorageControllers"]
            }
            
            # Fetch drives for this controller
            if controller["Drives"] && !controller["Drives"].empty?
              controller_data["drives"] = fetch_controller_drives(controller["@odata.id"])
            else
              controller_data["drives"] = []
            end
            
            controller_data
          end
          
          return controllers.sort_by { |c| c["name"] }
        rescue JSON::ParserError
          raise Error, "Failed to parse controllers response: #{response.body}"
        end
      else
        raise Error, "Failed to get controllers. Status code: #{response.status}"
      end
    end
    
    private
    
    def fetch_controller_drives(controller_id)
      controller_path = controller_id.split("v1/").last
      response = authenticated_request(:get, "/redfish/v1/#{controller_path}?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          drives = data["Drives"].map do |body|
            serial = body["SerialNumber"] 
            serial = body["Identifiers"].first["DurableName"] if serial.blank?
            {
              "id" => body["Id"],
              "name" => body["Name"],
              "serial" => serial,
              "manufacturer" => body["Manufacturer"],
              "model" => body["Model"],
              "revision" => body["Revision"],
              "capacity_bytes" => body["CapacityBytes"],
              "speed_gbps" => body["CapableSpeedGbs"],
              "rotation_speed_rpm" => body["RotationSpeedRPM"],
              "media_type" => body["MediaType"],
              "protocol" => body["Protocol"],
              "health" => body.dig("Status", "Health") || "N/A",
              "temperature_celsius" => nil,  # Not available in standard iDRAC
              "failure_predicted" => body["FailurePredicted"],
              "life_left_percent" => body["PredictedMediaLifeLeftPercent"],
              # Dell-specific fields
              "certified" => body.dig("Oem", "Dell", "DellPhysicalDisk", "Certified"),
              "raid_status" => body.dig("Oem", "Dell", "DellPhysicalDisk", "RaidStatus"),
              "operation_name" => body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationName"),
              "operation_progress" => body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationPercentCompletePercent"),
              "encryption_ability" => body["EncryptionAbility"],
              "odata_id" => body["@odata.id"]  # Full API path for operations
            }
          end
          
          return drives.sort_by { |d| d["name"] }
        rescue JSON::ParserError
          []
        end
      else
        []
      end
    end
    
    public

    # Find the best controller based on preference flags
    # @param name_pattern [String] Regex pattern to match controller name (defaults to "PERC")
    # @param prefer_most_drives_by_count [Boolean] Prefer controllers with more drives
    # @param prefer_most_drives_by_size [Boolean] Prefer controllers with larger total drive capacity
    # @return [Hash] The selected controller
    def find_controller(name_pattern: "PERC", prefer_most_drives_by_count: false, prefer_most_drives_by_size: false)
      all_controllers = controllers
      return nil if all_controllers.empty?
      
      # Filter by name pattern if provided
      if name_pattern
        pattern_matches = all_controllers.select { |c| c["name"] && c["name"].include?(name_pattern) }
        return pattern_matches.first if pattern_matches.any?
      end
      
      selected_controller = nil
      
      # If we prefer controllers by drive count
      if prefer_most_drives_by_count
        selected_controller = all_controllers.max_by { |c| c["drives_count"] || 0 }
      end
      
      # If we prefer controllers by total drive size
      if prefer_most_drives_by_size && !selected_controller
        # We need to calculate total drive size for each controller
        controller_with_most_capacity = nil
        max_capacity = -1
        
        all_controllers.each do |controller|
          # Get the drives for this controller
          controller_drives = begin
            drives(controller["@odata.id"])
          rescue
            [] # If we can't get drives, assume empty
          end
          
          # Calculate total capacity
          total_capacity = controller_drives.sum { |d| d["capacity_bytes"] || 0 }
          
          if total_capacity > max_capacity
            max_capacity = total_capacity
            controller_with_most_capacity = controller
          end
        end
        
        selected_controller = controller_with_most_capacity if controller_with_most_capacity
      end
      
      # Default to first controller if no preferences matched
      selected_controller || all_controllers.first
    end

    # Get information about physical drives
    def drives(controller_id) # expects @odata.id as string
      raise Error, "Controller ID not provided" unless controller_id
      raise Error, "Expected controller ID string, got #{controller_id.class}" unless controller_id.is_a?(String)
      
      controller_path = controller_id.split("v1/").last
      response = authenticated_request(:get, "/redfish/v1/#{controller_path}?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Debug dump of drive data - this happens with -vv or -vvv
          dump_drive_data(data["Drives"])
          
          drives = data["Drives"].map do |body|
            serial = body["SerialNumber"] 
            serial = body["Identifiers"].first["DurableName"] if serial.blank?
            {
              "id" => body["Id"],
              "name" => body["Name"],
              "serial" => serial,
              "manufacturer" => body["Manufacturer"],
              "model" => body["Model"],
              "revision" => body["Revision"],
              "capacity_bytes" => body["CapacityBytes"],
              "speed_gbps" => body["CapableSpeedGbs"],
              "rotation_speed_rpm" => body["RotationSpeedRPM"],
              "media_type" => body["MediaType"],
              "protocol" => body["Protocol"],
              "health" => body.dig("Status", "Health") || "N/A",
              "temperature_celsius" => nil,  # Not available in standard iDRAC
              "failure_predicted" => body["FailurePredicted"],
              "life_left_percent" => body["PredictedMediaLifeLeftPercent"],
              # Dell-specific fields
              "certified" => body.dig("Oem", "Dell", "DellPhysicalDisk", "Certified"),
              "raid_status" => body.dig("Oem", "Dell", "DellPhysicalDisk", "RaidStatus"),
              "operation_name" => body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationName"),
              "operation_progress" => body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationPercentCompletePercent"),
              "encryption_ability" => body["EncryptionAbility"],
              "odata_id" => body["@odata.id"]  # Full API path for operations
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

    # Helper method to display drive data in raw format
    def dump_drive_data(drives)
      
      self.debug "\n===== RAW DRIVE API DATA =====".green.bold
      drives.each_with_index do |drive, index|
        self.debug "\nDrive #{index + 1}: #{drive["Name"]}".cyan.bold
        self.debug "PredictedMediaLifeLeftPercent: #{drive["PredictedMediaLifeLeftPercent"].inspect}".yellow
        
        # Show other wear-related fields if they exist
        wear_fields = drive.keys.select { |k| k.to_s =~ /wear|life|health|predict/i }
        wear_fields.each do |field|
          self.debug "#{field}: #{drive[field].inspect}".yellow unless field == "PredictedMediaLifeLeftPercent"
        end
        
        # Show all data for full debug (verbosity level 3 / -vvv)
        self.debug "\nAll Drive Data:".light_magenta.bold
        self.debug JSON.pretty_generate(drive)
      end
      self.debug "\n===== END RAW DRIVE DATA =====\n".green.bold
    end

    # Get information about virtual disk volumes
    def volumes(controller_id) # expects @odata.id as string
      raise Error, "Controller ID not provided" unless controller_id
      raise Error, "Expected controller ID string, got #{controller_id.class}" unless controller_id.is_a?(String)
      
      puts "Volumes (e.g. Arrays)".green
      
      odata_id_path = controller_id + "/Volumes"
      response = authenticated_request(:get, "#{odata_id_path}?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Check if we need SCP data (older firmware)
          scp_data = nil
          controller_fqdd = controller_id.split("/").last
          
          # Get SCP data if needed (older firmware won't have these OEM attributes)
          if data["Members"].any? && 
             data["Members"].first&.dig("Oem", "Dell", "DellVirtualDisk", "WriteCachePolicy").nil?
            scp_data = get_system_configuration_profile(target: "RAID")
          end
          
          volumes = data["Members"].map do |vol|
            drives = vol["Links"]["Drives"]
            volume_data = { 
              "name" => vol["Name"], 
              "capacity_bytes" => vol["CapacityBytes"], 
              "volume_type" => vol["VolumeType"],
              "drives" => drives,
              "raid_level" => vol["RAIDType"],
              "encrypted" => vol["Encrypted"],
              "@odata.id" => vol["@odata.id"]
            }
            
            # Try to get cache policies from OEM data first (newer firmware)
            volume_data["write_cache_policy"] = vol.dig("Oem", "Dell", "DellVirtualDisk", "WriteCachePolicy")
            volume_data["read_cache_policy"] = vol.dig("Oem", "Dell", "DellVirtualDisk", "ReadCachePolicy")
            volume_data["stripe_size"] = vol.dig("Oem", "Dell", "DellVirtualDisk", "StripeSize")
            volume_data["lock_status"] = vol.dig("Oem", "Dell", "DellVirtualDisk", "LockStatus")
            
            # If we have SCP data and missing some policies, look them up from SCP
            if scp_data && (volume_data["write_cache_policy"].nil? || 
                            volume_data["read_cache_policy"].nil? || 
                            volume_data["stripe_size"].nil?)
              
              # Find controller component in SCP
              controller_comp = scp_data.dig("SystemConfiguration", "Components")&.find do |comp|
                comp["FQDD"] == controller_fqdd
              end
              
              if controller_comp
                # Try to find the matching virtual disk
                # Format is typically "Disk.Virtual.X:RAID...."
                # vd_name = vol["Id"] || vol["Name"]  # Not used, kept for debugging
                vd_comp = controller_comp["Components"]&.find do |comp|
                  comp["FQDD"] =~ /Disk\.Virtual\.\d+:#{controller_fqdd}/
                end
                
                if vd_comp && vd_comp["Attributes"]
                  # Extract values from SCP
                  write_policy = vd_comp["Attributes"].find { |a| a["Name"] == "RAIDdefaultWritePolicy" }
                  read_policy = vd_comp["Attributes"].find { |a| a["Name"] == "RAIDdefaultReadPolicy" }
                  stripe = vd_comp["Attributes"].find { |a| a["Name"] == "StripeSize" }
                  lock_status = vd_comp["Attributes"].find { |a| a["Name"] == "LockStatus" }
                  raid_level = vd_comp["Attributes"].find { |a| a["Name"] == "RAIDTypes" }
                  
                  volume_data["write_cache_policy"] ||= write_policy&.dig("Value")
                  volume_data["read_cache_policy"] ||= read_policy&.dig("Value")
                  volume_data["stripe_size"] ||= stripe&.dig("Value")
                  volume_data["lock_status"] ||= lock_status&.dig("Value")
                  volume_data["raid_level"] ||= raid_level&.dig("Value")
                end
              end
            end
            
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

      # Note for older firmware, the stripe size is misreported as 128KB when it is actually 64KB (seen through the DELL Web UI), so ignore that:
      firmware_version = get_firmware_version.split(".")[0,2].join.to_i
      if firmware_version < 440
        stripe_size = "64KB"
      else
        stripe_size = volume["stripe_size"]
      end

      if volume["write_cache_policy"] == "WriteThrough" && 
         volume["read_cache_policy"] == "NoReadAhead" && 
         stripe_size == "64KB"
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

      handle_response(response)
    end

    # Create a new virtual disk with RAID5 and FastPath optimizations
    def create_virtual_disk(controller_id:, drives:, name: "vssd0", raid_type: "RAID5", encrypt: true)
      raise "Drives must be an array of @odata.id strings" unless drives.all? { |d| d.is_a?(String) }
      
      # Get firmware version to determine approach
      firmware_version = get_firmware_version.split(".")[0,2].join.to_i
      
      # For older iDRAC firmware, use SCP method instead of API
      if firmware_version < 440
        return create_virtual_disk_scp(
          controller_id: controller_id,
          drives: drives,
          name: name,
          raid_type: raid_type,
          encrypt: encrypt
        )
      end
      
      # For newer firmware, use Redfish API
      drive_refs = drives.map { |d| { "@odata.id" => d.to_s } }
      
      # [FastPath optimization for SSDs](https://www.dell.com/support/manuals/en-us/perc-h755/perc11_ug/fastpath?guid=guid-a9e90946-a41f-48ab-88f1-9ce514b4c414&lang=en-us)
      payload = {
        "Links" => { "Drives" => drive_refs },
        "Name" => name,
        "OptimumIOSizeBytes" => 64 * 1024,
        "Oem" => { "Dell" => { "DellVolume" => { "DiskCachePolicy" => "Enabled" } } },
        "ReadCachePolicy" => "Off", # "NoReadAhead"
        "WriteCachePolicy" => "WriteThrough"
      }
      
      # For modern firmware
      if drives.size < 3 && raid_type == "RAID5"
        debug "Less than 3 drives. Selecting RAID0.", 1, :red
        payload["RAIDType"] = "RAID0"
      else
        payload["RAIDType"] = raid_type
      end
      
      payload["Encrypted"] = true if encrypt
      
      response = authenticated_request(
        :post, 
        "#{controller_id}/Volumes",
        body: payload.to_json, 
        headers: { 'Content-Type' => 'application/json' }
      )
      
      handle_response(response)
    end


    ########################################################
    # System Configuration Profile - based VSSD0
    #   This is required for older DELL iDRAC that
    #   doesn't support the POST method with cache policies
    #   nor encryption. 
    #   When we remove 630/730's, we can remove this.
    ########################################################
    # We want one volume -- vssd0, RAID5, NO READ AHEAD, WRITE THROUGH, 64K STRIPE, ALL DISKS
    # All we are doing here is manually setting WriteThrough. The rest is set correctly from
    # the create_vssd0_post method.
    # [FastPath](https://www.dell.com/support/manuals/en-us/poweredge-r7525/perc11_ug/fastpath?guid=guid-a9e90946-a41f-48ab-88f1-9ce514b4c414&lang=en-us)
    # The PERC 11 series of cards support FastPath. To enable FastPath on a virtual disk, the
    # cache policies of the RAID controller must be set to **write-through and no read ahead**.
    # This enables FastPath to use the proper data path through the controller based on command 
    # (read/write), I/O size, and RAID type. For optimal solid-state drive performance, 
    # create virtual disks with **strip size of 64 KB**.
    # Rest from:
    # https://github.com/dell/iDRAC-Redfish-Scripting/blob/cc88a3db1bfb6cb5c6eea938ea6da67a84fb1dad/Redfish%20Python/CreateVirtualDiskREDFISH.py
    # Create a RAID virtual disk using SCP for older iDRAC firmware
    def create_virtual_disk_scp(controller_id:, drives:, name: "vssd0", raid_type: "RAID5", encrypt: true)
      # Extract the controller FQDD from controller_id
      controller_fqdd = controller_id.split("/").last
      
      # Get drive IDs in the required format
      drive_ids = drives.map do |drive_path|
        # Extract the disk FQDD from @odata.id
        drive_id = drive_path.split("/").last
        if drive_id.include?(":") # Already in FQDD format
          drive_id
        else
          # Need to convert to FQDD format
          "Disk.Bay.#{drive_id}:#{controller_fqdd}"
        end
      end
      
      # Map RAID type to proper format
      raid_level = case raid_type
                   when "RAID0" then "0"
                   when "RAID1" then "1"
                   when "RAID5" then "5"
                   when "RAID6" then "6"
                   when "RAID10" then "10"
                   else raid_type.gsub("RAID", "")
                   end
      
      # Create the virtual disk component
      vd_component = {
        "FQDD" => "Disk.Virtual.0:#{controller_fqdd}",
        "Attributes" => [
          { "Name" => "RAIDaction", "Value" => "Create", "Set On Import" => "True" },
          { "Name" => "Name", "Value" => name, "Set On Import" => "True" },
          { "Name" => "RAIDTypes", "Value" => "RAID #{raid_level}", "Set On Import" => "True" },
          { "Name" => "StripeSize", "Value" => "64KB", "Set On Import" => "True" }, # 64KB needed for FastPath
          { "Name" => "RAIDdefaultWritePolicy", "Value" => "WriteThrough", "Set On Import" => "True" },
          { "Name" => "RAIDdefaultReadPolicy", "Value" => "NoReadAhead", "Set On Import" => "True" },
          { "Name" => "DiskCachePolicy", "Value" => "Enabled", "Set On Import" => "True" }
        ]
      }
      
      # Add encryption if requested
      if encrypt
        vd_component["Attributes"] << { "Name" => "LockStatus", "Value" => "Unlocked", "Set On Import" => "True" }
      end
      
      # Add the include physical disks
      drive_ids.each do |disk_id|
        vd_component["Attributes"] << { 
          "Name" => "IncludedPhysicalDiskID", 
          "Value" => disk_id, 
          "Set On Import" => "True" 
        }
      end
      
      # Create an SCP with the controller component that contains the VD component
      controller_component = {
        "FQDD" => controller_fqdd,
        "Components" => [vd_component]
      }
      
      # Apply the SCP
      scp = { "SystemConfiguration" => { "Components" => [controller_component] } }
      result = set_system_configuration_profile(scp, target: "RAID", reboot: false)
      
      if result[:status] == :success
        return { status: :success, job_id: result[:job_id] }
      else
        raise Error, "Failed to create virtual disk: #{result[:error] || 'Unknown error'}"
      end
    end

    # Enable Self-Encrypting Drive support on controller
    def enable_local_key_management(controller_id:, passphrase: "Secure123!", key_id: "RAID-Key-2023")
      payload = { 
        "TargetFQDD": controller_id, 
        "Key": passphrase, 
        "Keyid": key_id 
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
