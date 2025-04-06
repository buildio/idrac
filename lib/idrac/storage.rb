require 'json'
require 'colorize'
require 'recursive-open-struct'

module IDRAC
  module Storage
    # Get storage controllers information
    def controller
      # Use the controllers method to get all controllers
      controller_list = controllers
      
      puts "Controllers".green
      controller_list.each { |c| puts "#{c.name} > #{c.drives_count}" }
      
      puts "Drives".green
      controller_list.each do |c|
        puts "Storage: #{c.name} > #{c.status} > #{c.drives_count}"
      end
      
      # Find the controller with the most drives (usually the PERC)
      controller_info = controller_list.max_by { |c| c.drives_count }
      
      if controller_info.name =~ /PERC/
        puts "Found #{controller_info.name}".green
      else
        puts "Found #{controller_info.name} but continuing...".yellow
      end
      
      # Return the raw controller data
      controller_info.raw
    end

    # Get all storage controllers and return them as an array
    def controllers
      response = authenticated_request(:get, '/redfish/v1/Systems/System.Embedded.1/Storage?$expand=*($levels=1)')
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Transform and return all controllers as an array of RecursiveOpenStruct objects with consistent keys
          controllers = data["Members"].map do |controller|
            controller_data = {
              name: controller["Name"],
              model: controller["Model"],
              drives_count: controller["Drives"].size,
              status: controller["Status"]["Health"] || "N/A",
              firmware_version: controller.dig("StorageControllers", 0, "FirmwareVersion"),
              encryption_mode: controller.dig("Oem", "Dell", "DellController", "EncryptionMode"),
              encryption_capability: controller.dig("Oem", "Dell", "DellController", "EncryptionCapability"),
              controller_type: controller.dig("Oem", "Dell", "DellController", "ControllerType"),
              pci_slot: controller.dig("Oem", "Dell", "DellController", "PCISlot"),
              raw: controller,
              volumes_odata_id: controller.dig("Volumes", "@odata.id"),
              odata_id: controller["@odata.id"]
            }
            
            RecursiveOpenStruct.new(controller_data, recurse_over_arrays: true)
          end
          
          return controllers.sort_by { |c| c.name }
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
            drive_data = { 
              serial: serial,
              model: body["Model"],
              name: body["Name"],
              capacity_bytes: body["CapacityBytes"],
              health: body["Status"]["Health"] ? body["Status"]["Health"] : "N/A",
              speed_gbp: body["CapableSpeedGbs"],
              manufacturer: body["Manufacturer"],
              media_type: body["MediaType"],
              failure_predicted: body["FailurePredicted"],
              life_left_percent: body["PredictedMediaLifeLeftPercent"],
              certified: body.dig("Oem", "Dell", "DellPhysicalDisk", "Certified"),
              raid_status: body.dig("Oem", "Dell", "DellPhysicalDisk", "RaidStatus"),
              operation_name: body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationName"),
              operation_progress: body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationPercentCompletePercent"),
              encryption_ability: body["EncryptionAbility"],
              odata_id: body["@odata.id"]
            }
            
            RecursiveOpenStruct.new(drive_data, recurse_over_arrays: true)
          end
          
          return drives.sort_by { |d| d.name }
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
      
      odata_id_path = controller.dig("volumes_odata_id") || controller.volumes_odata_id
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
              "odata_id" => vol["@odata.id"]
            }
            
            # Check FastPath settings
            volume_data['fastpath'] = fastpath_good?(volume_data)
            
            # Handle volume operations and status
            if vol["Operations"].any?
              volume_data['health'] = vol["Status"]["Health"] ? vol["Status"]["Health"] : "N/A"
              volume_data['progress'] = vol["Operations"].first["PercentageComplete"]
              volume_data['message'] = vol["Operations"].first["OperationName"]     
            elsif vol["Status"]["Health"] == "OK"
              volume_data['health'] = "OK"
              volume_data['progress'] = nil
              volume_data['message'] = nil
            else
              volume_data['health'] = "?"
              volume_data['progress'] = nil
              volume_data['message'] = nil
            end
            
            # Create the RecursiveOpenStruct after all properties are set
            RecursiveOpenStruct.new(volume_data, recurse_over_arrays: true)
          end
          
          return volumes.sort_by { |d| d.name }
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
      if volume['write_cache_policy'] == "WriteThrough" && 
         volume['read_cache_policy'] == "NoReadAhead" && 
         volume['stripe_size'] == "64KB"
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
      drives.all? { |d| d.encryption_ability == "SelfEncryptingDrive" }
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
  end
end 
=begin
  def controller_encryption_capable?
    self.meta.dig("controller", "Oem", "Dell", "DellController", "EncryptionCapability") =~ /localkey/i # "LocalKeyManagementAndSecureEnterpriseKeyManagerCapable"
  end
  def controller_encryption_enabled?
    self.meta.dig("controller", "Oem", "Dell", "DellController", "EncryptionMode") =~ /localkey/i
  end
  def drives
    # Get the drives
    controller_path = self.controller["@odata.id"].split("v1/").last
    json = get(path: "#{controller_path}?$expand=*($levels=1)")["body"]["Drives"]
    # drives = self.controller["Drives"].collect 
    idrac_drives = json.map do |body|
      # path = d["@odata.id"].split("v1/").last
      # body = self.get(path: path)["body"]
      serial = body["SerialNumber"] 
      serial = body["Identifiers"].first["DurableName"] if serial.blank?
      { 
        serial: serial,
        model: body["Model"],
        name: body["Name"],
        capacity_bytes: body["CapacityBytes"],
        # Health is nil when powered off...
        health: body["Status"]["Health"] ? body["Status"]["Health"] : "N/A",
        speed_gbp: body["CapableSpeedGbs"],
        manufacturer: body["Manufacturer"],
        media_type: body["MediaType"],
        failure_predicted: body["FailurePredicted"],
        life_left_percent: body["PredictedMediaLifeLeftPercent"],
        certified: body.dig("Oem", "Dell", "DellPhysicalDisk", "Certified"),
        raid_status: body.dig("Oem", "Dell", "DellPhysicalDisk", "RaidStatus"),
        operation_name: body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationName"),
        operation_progress: body.dig("Oem", "Dell", "DellPhysicalDisk", "OperationPercentCompletePercent"),
        encryption_ability: body["EncryptionAbility"],
        "@odata.id": body["@odata.id"]
      }
    end
    self.meta["drives"] = idrac_drives.sort_by { |d| d[:name] }
    if self.save
      self.meta["drives"]
    else
      false
    end
  end
  def volumes
    puts "Volumes (e.g. Arrays)".green
    # {"@odata.id"=>"/redfish/v1/Systems/System.Embedded.1/Storage/RAID.Integrated.1-1/Volumes"}

    v = self.controller["Volumes"]
    path = v["@odata.id"].split("v1/").last
    vols = self.get(path: path+"?$expand=*($levels=1)")["body"]  
    volumes = vols["Members"].collect do |vol|
      drives = vol["Links"]["Drives"]
      volume = { 
        name: vol["Name"], 
        capacity_bytes: vol["CapacityBytes"], 
        volume_type: vol["VolumeType"],
        drives: drives,
        write_cache_policy: vol.dig("Oem", "Dell", "DellVirtualDisk", "WriteCachePolicy"),
        read_cache_policy:  vol.dig("Oem", "Dell", "DellVirtualDisk", "ReadCachePolicy"),
        stripe_size: vol.dig("Oem", "Dell", "DellVirtualDisk", "StripeSize"),
        raid_level:  vol["RAIDType"],
        encrypted: vol["Encrypted"],
        lock_status: vol.dig("Oem", "Dell", "DellVirtualDisk", "LockStatus"),
        # "Operations"=>[{"OperationName"=>"Background Initialization", "PercentageComplete"=>0}],
        "@odata.id": vol["@odata.id"]
      }
      if !self.modern_firmware?
        # Unfortunately for older idracs, to get the drive cache policies we need to do a 
        # system_configuration_profile call AND we still don't get the right stripe size.
        scp ||= self.get_system_configuration_profile(target: "RAID")
        controller = self.meta["controller"]
        scp_vol = scp["SystemConfiguration"]["Components"]
                   .find { |comp| comp["FQDD"] == controller['Id'] }["Components"]
                   .find { |comp| comp["FQDD"] == vol["Id"] }["Attributes"]
        # .find { |attr| attr["Name"] == "RAIDdefaultWritePolicy" }["Value"]
        volume[:write_cache_policy] = scp_vol.find { |attr| attr["Name"] == "RAIDdefaultWritePolicy" }["Value"]
        volume[:read_cache_policy]  = scp_vol.find { |attr| attr["Name"] == "RAIDdefaultReadPolicy" }["Value"]
      end


      # Dell-specific high-performance settings for PERC:
      # [Read more](https://www.dell.com/support/manuals/en-us/perc-h755/perc11_ug/fastpath?guid=guid-a9e90946-a41f-48ab-88f1-9ce514b4c414&lang=en-us)
      volume[:fastpath] = self.fastpath_good?(volume)

      # Not built yet:
      #     "Status"=>{"Health"=>nil, "HealthRollup"=>nil, "State"=>"Enabled"},
      # Dunno
      #     "Status"=>{"Health"=>"OK", "HealthRollup"=>"OK", "State"=>"Enabled"},
      # In progress:
      #     "Operations"=>[{"OperationName"=>"Background Initialization", "PercentageComplete"=>0}],
      #     "Status"=>{"Health"=>nil, "HealthRollup"=>nil, "State"=>"Enabled"},
      if vol["Operations"].any?
        volume[:health]   = vol["Status"]["Health"] ? vol["Status"]["Health"] : "N/A"
        volume[:progress] = vol["Operations"].first["PercentageComplete"]
        volume[:message]  = vol["Operations"].first["OperationName"]     
      elsif vol["Status"]["Health"] == "OK"
        volume[:health]   = "OK"
        volume[:progress] = nil
        volume[:message]  = nil
      else
        volume[:health]   = "?"
        volume[:progress] = nil
        volume[:message]  = nil
      end
      volume
    end
    self.meta["volumes"] = volumes.sort_by { |d| d[:name] }
    self.save
  end
  def memory
    expected = expected_memory
    mem = self.get(path: "Systems/System.Embedded.1/Memory?$expand=*($levels=1)")["body"]
    memory = mem["Members"].map do |m|
      dimm_name = m["Name"] # e.g. DIMM A1
      bank, index = /DIMM ([A-Z])(\d+)/.match(dimm_name).captures
      # We expect one of our configurations:
      # 32GB DIMMS x 32 = 1TB   # Gen III, less memory issues (we've experienced too many bad 64GB DIMMS)
      # 64GB DIMMS x 24 = 1.5TB # Gen II
      # 64GB DIMMS x 32 = 2TB   # Gen I
      expected.delete(dimm_name) if expected[dimm_name] == m["CapacityMiB"] * 1.megabyte || expected[dimm_name] == m["CapacityMiB"] * 1.megabyte * 2
      puts "DIMM: #{m["Model"]} #{m["Name"]} > #{m["CapacityMiB"]}MiB > #{m["Status"]["Health"]} > #{m["OperatingSpeedMhz"]}MHz > #{m["PartNumber"]} / #{m["SerialNumber"]}"
      { 
        "model" => m["Model"], 
        "name" => m["Name"], 
        "capacity_bytes" => m["CapacityMiB"].to_i * 1.megabyte, 
        "health" => m["Status"]["Health"] ? m["Status"]["Health"] : "N/A", 
        "speed_mhz" => m["OperatingSpeedMhz"], 
        "part_number" => m["PartNumber"], 
        "serial" => m["SerialNumber"],
        "bank" => bank,
        "index" => index.to_i
      }
    end
    self.meta["memory"] = memory.sort_by { |a| [a["bank"], a["index"]] }
    if expected.any?
      log("Missing DIMMs: #{expected.keys.join(", ")}".red)
      puts "Missing DIMMs: #{expected.keys.join(", ")}".red
    end
    self.save
  end
  def pci(force: false)
    # If we've already found two Mellanox cards, let's not refresh by default
    if !force && (2 == self.meta["pci"]&.select { |p| p['manufacturer'] =~ /Mellanox/ }&.size)
      puts "[PCI] 2 x Mellanox NICs already found. Skipping.".yellow
      return
    end
    # /redfish/v1/Chassis/System.Embedded.1/PCIeDevices/59-0/PCIeFunctions/59-0-0
    # Look at all the PCI slots and ideally identify the Mellanox cards
    # Then match them to the 
    devices = self.get(path: "Chassis/System.Embedded.1/PCIeDevices?$expand=*($levels=1)")["body"]
    pci = devices["Members"].map do |stub|
      manufacturer = stub["Manufacturer"]
      pcie_function_path = stub.dig("Links", "PCIeFunctions", 0, "@odata.id")
      device = self.get(path: pcie_function_path)["body"]

      # If it's a network device, we can chcek the link to its PCIe details and then 
      # NetworkController
      puts "PCI Device: #{device["Name"]} > #{manufacturer} > #{device["DeviceClass"]} > #{device["Description"]} > #{device["Id"]}"
      { device_class: device["DeviceClass"], # e.g. NetworkController
        manufacturer: manufacturer,
        name: device["Name"],
        description: device["Description"],
        id: device["Id"], # This is the BUS: e.g. 59-0-0 => 3b
        slot_type: device.dig("Oem", "Dell", "DellPCIeFunction", "SlotType"),
        bus_width: device.dig("Oem", "Dell", "DellPCIeFunction", "DataBusWidth"),
        nic: device.dig("Links", "EthernetInterfaces", 0, "@odata.id")
      }
    end
    self.meta['pci'] = pci
    self.save
  end
  # Finds Mellanox cards on the bus and their NICs.
  # [{:bus_id=>"59", :nic=>"NIC.Slot.1-1-1"}, {:bus_id=>"94", :nic=>"NIC.Slot.2-1-1"}] 
  def nics_to_pci
    self.nics if self.meta['nics'].blank?
    self.pci  if self.meta['pci'].blank?
    hsh = self.meta['pci']&.select { |n| n['device_class'] =~ /NetworkController/ && n['manufacturer'] =~ /Mellanox/ }&.inject({}) do |acc,v| 
      nic = (v['nic'] =~ /.*\/([^\/\-]+-\d+)/; $1) # e.g. NIC.Slot.1-1 # Drop one -1 for consistency with other iDRAC
      pci = (v['id'] =~ /^(\d+)-\d+-\d/; $1)  # e.g. 59
      acc[nic] = pci
      acc
    end
    self.meta['nics'].each do |nic|
      nic['ports'].each do |port| 
        pci_bus = hsh[port['name']] 
        if pci_bus
          port['pci'] = pci_bus
          port['linux_device'] = "enp#{pci_bus}s0np0" # e.g. enp3s0np0
        end
      end
    end
    hsh
  end
  def nics
    # There can be multiple NIC adapters, so first we enumerate them:
    adapters = self.get(path: "Systems/System.Embedded.1/NetworkAdapters?$expand=*($levels=1)")["body"]
    nics     = adapters["Members"].map do |adapter|
      port_part = self.idrac_license_version.to_i == 9 ? 'Ports' : 'NetworkPorts'
      path  = "#{adapter["@odata.id"].split("v1/").last}/#{port_part}?$expand=*($levels=1)"
      res   = self.get(path: path)["body"]
      ports = res["Members"].collect do |nic|
        link_speed_mbps, mac_addr, link_status = nil, nil, nil
        if self.idrac_license_version.to_i == 9
          link_speed_mbps = nic['CurrentSpeedGbps'].to_i * 1000
          mac_addr = nic['Ethernet']['AssociatedMACAddresses'].first
          port_num = nic['PortId']
          network_technology = nic['LinkNetworkTechnology']
          link_status = nic['LinkStatus'] =~ /up/i ? "Up" : "Down" # Lovely, iDRAC now uses LinkUp instead of Up. :shrug:
        else # iDRAC 8
          link_speed_mbps = nic["SupportedLinkCapabilities"].first["LinkSpeedMbps"]
          mac_addr        = nic["AssociatedNetworkAddresses"].first
          port_num        = nic["PhysicalPortNumber"]
          network_technology = nic["SupportedLinkCapabilities"].first["LinkNetworkTechnology"]
          link_status = nic['LinkStatus']
        end
        puts "NIC: #{nic["Id"]} > #{mac_addr} > #{link_status} > #{port_num} > #{link_speed_mbps}Mbps"
        { 
          "name" => nic["Id"], 
          "status" => link_status,
          "mac" => mac_addr,
          "port" => port_num,
          "speed_mbps" => link_speed_mbps,
          "kind" => network_technology&.downcase
        }
      end
      {
        "name" =>  adapter["Id"],                     # "NIC.Integrated.1-1",
        "manufacturer" => adapter["Manufacturer"],    # "Mellanox Technologies",
        "model" => adapter["Model"],                  # "MLNX 100GbE 2P ConnectX6 Adpt"
        "part_number" => adapter["PartNumber"],       # "08AAAA",
        "serial" => adapter["SerialNumber"],          # "TW78AAAAAAAAAA",
        "ports" => ports
      }
    end
    # Now let's parse the NICs and make sure we have a PORT for each one.
    # Note that we set the MAC address for the MANAGEMENT port by a heuristic!!!
    # If we ever see a 1000 Mbps port in the NIC.Integrated or NIC.Embedded, that's the Managament Port!
    nics.each do |nic|
      # puts nic.inspect
      nic["ports"].each do |port|
        # puts port.inspect
        if port["speed_mbps"] == 1000 && 
          (port["name"] =~ /NIC.Integrated/ || nic["name"] =~ /NIC.Embedded/) &&
           port['status'] == 'Up' &&
           port['kind'] == 'ethernet' &&
           port['mac'] =~ /([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2})/
          Rails.logger.debug "Identified Management Port: #{port['name']} #{port['mac']}".blue
          self.management_port.update(mac_addr: port["mac"])
        end
      end
    end
    self.meta["nics"] = nics
    self.save
  end

=end