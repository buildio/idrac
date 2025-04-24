require 'json'
require 'colorize'

module IDRAC
  module System
    # Get memory information
    def memory
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/Memory?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          memory = data["Members"].map do |m|
            dimm_name = m["Name"] # e.g. DIMM A1
            bank, index = /DIMM ([A-Z])(\d+)/.match(dimm_name).captures
            
            {
              "model" => m["Model"], 
              "name" => m["Name"], 
              "capacity_bytes" => m["CapacityMiB"].to_i * 1024 * 1024, 
              "health" => m.dig("Status","Health") || "N/A", 
              "speed_mhz" => m["OperatingSpeedMhz"], 
              "part_number" => m["PartNumber"], 
              "serial" => m["SerialNumber"],
              "bank" => bank,
              "index" => index.to_i
            }
          end
          
          return memory.sort_by { |m| [m["bank"] || "Z", m["index"] || 999] }
        rescue JSON::ParserError
          raise Error, "Failed to parse memory response: #{response.body}"
        end
      else
        raise Error, "Failed to get memory. Status code: #{response.status}"
      end
    end

    # Get power supply information
    def psus
      response = authenticated_request(:get, "/redfish/v1/Chassis/System.Embedded.1/Power")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          puts "Power Supplies".green
          
          psus = data["PowerSupplies"].map do |psu|
            puts "PSU: #{psu["Name"]} > #{psu["PowerInputWatts"]}W > #{psu.dig("Status", "Health")}"
            {
              "name" => psu["Name"], 
              "voltage" => psu["LineInputVoltage"], 
              "voltage_human" => psu["LineInputVoltageType"], # AC240V
              "watts" => psu["PowerInputWatts"],
              "part" => psu["PartNumber"],
              "model" => psu["Model"],
              "serial" => psu["SerialNumber"],
              "status" => psu.dig("Status", "Health")
            }
          end
          
          return psus
        rescue JSON::ParserError
          raise Error, "Failed to parse PSU response: #{response.body}"
        end
      else
        raise Error, "Failed to get PSUs. Status code: #{response.status}"
      end
    end

    # Get fan information
    def fans
      tries = 0
      max_tries = 3
      
      while tries < max_tries
        begin
          response = authenticated_request(:get, "/redfish/v1/Chassis/System.Embedded.1/Thermal?$expand=*($levels=1)")
          
          if response.status == 200
            data = JSON.parse(response.body)
            
            fans = data["Fans"].map do |fan|
              puts "Fan: #{fan["Name"]} > #{fan["Reading"]} > #{fan.dig("Status", "Health")}"
              {
                "name" => fan["Name"], 
                "rpm" => fan["Reading"],
                "serial" => fan["SerialNumber"],
                "status" => fan.dig("Status", "Health")
              }
            end
            
            return fans
          elsif response.status.between?(400, 499)
            # Check if system is powered off
            power_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$select=PowerState")
            if power_response.status == 200 && JSON.parse(power_response.body)["PowerState"] == "Off"
              puts "WARN: System is off. Fans are not available.".yellow
              return []
            end
          end
        rescue => e
          puts "WARN: Error getting fans: #{e.message}".yellow
        end
        
        tries += 1
        puts "Failed to get fans. Retrying #{tries}/#{max_tries}.".red if tries < max_tries
        sleep 10
      end
      
      puts "Failed to get fans after #{max_tries} tries".red
      return []
    end

    # Get NIC information
    def nics
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          adapters_data = JSON.parse(response.body)
          
          # Determine iDRAC version for different port paths
          idrac_version_response = authenticated_request(:get, "/redfish/v1")
          idrac_version_data = JSON.parse(idrac_version_response.body)
          server = idrac_version_data["RedfishVersion"] || idrac_version_response.headers["server"]
          
          is_idrac9 = case server.to_s.downcase
                      when /idrac\/9/
                        true
                      when /idrac\/8/
                        false
                      when /appweb\/4.5/
                        false
                      else
                        # Default to newer format for unknown versions
                        true
                      end
          
          port_part = is_idrac9 ? 'Ports' : 'NetworkPorts'
          
          nics = adapters_data["Members"].map do |adapter|
            path = "#{adapter["@odata.id"].split("v1/").last}/#{port_part}?$expand=*($levels=1)"
            ports_response = authenticated_request(:get, "/redfish/v1/#{path}")
            
            if ports_response.status == 200
              ports_data = JSON.parse(ports_response.body)
              
              ports = ports_data["Members"].map do |nic|
                if is_idrac9
                  link_speed_mbps = nic['CurrentSpeedGbps'].to_i * 1000
                  mac_addr = nic['Ethernet']['AssociatedMACAddresses'].first
                  port_num = nic['PortId']
                  network_technology = nic['LinkNetworkTechnology']
                  link_status = nic['LinkStatus'] =~ /up/i ? "Up" : "Down"
                else # iDRAC 8
                  link_speed_mbps = nic["SupportedLinkCapabilities"].first["LinkSpeedMbps"]
                  mac_addr = nic["AssociatedNetworkAddresses"].first
                  port_num = nic["PhysicalPortNumber"]
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
                "name" => adapter["Id"],
                "manufacturer" => adapter["Manufacturer"],
                "model" => adapter["Model"],
                "part_number" => adapter["PartNumber"],
                "serial" => adapter["SerialNumber"],
                "ports" => ports
              }
            else
              # Return adapter info without ports if we can't get port details
              {
                "name" => adapter["Id"],
                "manufacturer" => adapter["Manufacturer"],
                "model" => adapter["Model"],
                "part_number" => adapter["PartNumber"],
                "serial" => adapter["SerialNumber"],
                "ports" => []
              }
            end
          end
          
          return nics
        rescue JSON::ParserError
          raise Error, "Failed to parse NICs response: #{response.body}"
        end
      else
        raise Error, "Failed to get NICs. Status code: #{response.status}"
      end
    end

    # Get iDRAC network information
    def idrac_network
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/iDRAC.Embedded.1%23NIC.1")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          idrac = {
            "name" => data["Id"],
            "status" => data.dig("Status", "Health") == 'OK' ? 'Up' : 'Down',
            "mac" => data["MACAddress"],
            "mask" => data["IPv4Addresses"].first["SubnetMask"],
            "ipv4" => data["IPv4Addresses"].first["Address"],
            "origin" => data["IPv4Addresses"].first["AddressOrigin"], # DHCP or Static
            "port" => nil,
            "speed_mbps" => data["SpeedMbps"],
            "kind" => "ethernet"
          }
          
          return idrac
        rescue JSON::ParserError
          raise Error, "Failed to parse iDRAC network response: #{response.body}"
        end
      else
        raise Error, "Failed to get iDRAC network. Status code: #{response.status}"
      end
    end

    # Get PCI device information
    def pci_devices
      # First try the standard PCIeDevices endpoint
      response = authenticated_request(:get, "/redfish/v1/Chassis/System.Embedded.1/PCIeDevices?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          pci = data["Members"].map do |stub|
            manufacturer = stub["Manufacturer"]
            
            # Get PCIe function details if available
            pcie_function = nil
            if stub.dig("Links", "PCIeFunctions", 0, "@odata.id")
              pcie_function_path = stub.dig("Links", "PCIeFunctions", 0, "@odata.id").split("v1/").last
              function_response = authenticated_request(:get, "/redfish/v1/#{pcie_function_path}")
              
              if function_response.status == 200
                pcie_function = JSON.parse(function_response.body)
              end
            end
            
            # Create device info with available data
            device_info = {
              "device_class" => pcie_function ? pcie_function["DeviceClass"] : nil,
              "manufacturer" => manufacturer,
              "name" => stub["Name"],
              "description" => stub["Description"],
              "id" => pcie_function ? pcie_function["Id"] : stub["Id"],
              "slot_type" => pcie_function ? pcie_function.dig("Oem", "Dell", "DellPCIeFunction", "SlotType") : nil,
              "bus_width" => pcie_function ? pcie_function.dig("Oem", "Dell", "DellPCIeFunction", "DataBusWidth") : nil,
              "nic" => pcie_function ? pcie_function.dig("Links", "EthernetInterfaces", 0, "@odata.id") : nil
            }
            
            puts "PCI Device: #{device_info["name"]} > #{device_info["manufacturer"]} > #{device_info["device_class"]} > #{device_info["description"]} > #{device_info["id"]}"
            
            device_info
          end
          
          return pci
        rescue JSON::ParserError
          raise Error, "Failed to parse PCI devices response: #{response.body}"
        end
      else
        # For iDRAC 8, try Dell's recommended approach using System endpoint with PCIeDevices select option
        system_pcie_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$select=PCIeDevices")
        
        if system_pcie_response.status == 200
          begin 
            system_data = JSON.parse(system_pcie_response.body)
            
            if system_data.key?("PCIeDevices") && !system_data["PCIeDevices"].empty?
              pci_devices = []
              
              # Process each PCIe device
              system_data["PCIeDevices"].each do |device_link|
                if device_link.is_a?(Hash) && device_link["@odata.id"]
                  device_path = device_link["@odata.id"]
                  device_response = authenticated_request(:get, device_path)
                  
                  if device_response.status == 200
                    device_data = JSON.parse(device_response.body)
                    
                    pci_devices << {
                      "device_class" => device_data["DeviceType"] || "Unknown",
                      "manufacturer" => device_data["Manufacturer"],
                      "name" => device_data["Name"] || device_data["Id"],
                      "description" => device_data["Description"],
                      "id" => device_data["Id"],
                      "slot_type" => device_data.dig("Oem", "Dell", "SlotType"),
                      "bus_width" => device_data.dig("Oem", "Dell", "BusWidth"),
                      "nic" => nil
                    }
                  end
                end
              end
              
              return pci_devices unless pci_devices.empty?
            end
          rescue JSON::ParserError
            # Continue to next approach
          end
        end
        
        # Try NetworkAdapters as an alternative for finding PCIe devices (especially NICs and FC adapters)
        nic_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/NetworkAdapters?$expand=*($levels=1)")
        
        if nic_response.status == 200
          begin
            nic_data = JSON.parse(nic_response.body)
            
            pci_devices = []
            
            # Extract PCI info from network adapters
            if nic_data["Members"] && !nic_data["Members"].empty?
              nic_data["Members"].each do |adapter|
                next unless adapter["Model"] || adapter["Manufacturer"]
                
                # Check if this is a Fiber Channel adapter by name or model
                is_fc = (adapter["Name"] =~ /FC/i || adapter["Model"] =~ /FC/i || 
                         adapter["Id"] =~ /FC/i || adapter["Description"] =~ /Fibre/i) ? true : false
                
                device_class = is_fc ? "FibreChannelController" : "NetworkController"
                
                pci_devices << {
                  "device_class" => device_class,
                  "manufacturer" => adapter["Manufacturer"],
                  "name" => adapter["Name"] || adapter["Id"],
                  "description" => adapter["Description"],
                  "id" => adapter["Id"],
                  "slot_type" => adapter.dig("Oem", "Dell", "SlotType") || 
                                 (adapter["Id"] =~ /Slot\.(\d+)/ ? "Slot #{$1}" : nil),
                  "bus_width" => nil,
                  "nic" => adapter["@odata.id"]
                }
              end
              
              return pci_devices unless pci_devices.empty?
            end
          rescue JSON::ParserError
            # Continue to fallback
          end
        end
        
        # Last resort: check if PCIeFunctions are directly available
        pcie_functions_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/PCIeFunctions?$expand=*($levels=1)")
        
        if pcie_functions_response.status == 200
          begin
            functions_data = JSON.parse(pcie_functions_response.body)
            
            if functions_data["Members"] && !functions_data["Members"].empty?
              pci_devices = functions_data["Members"].map do |function|
                {
                  "device_class" => function["DeviceClass"] || "Unknown",
                  "manufacturer" => function["Manufacturer"] || "Unknown",
                  "name" => function["Name"] || function["Id"],
                  "description" => function["Description"],
                  "id" => function["Id"],
                  "slot_type" => function.dig("Oem", "Dell", "SlotType"),
                  "bus_width" => function.dig("Oem", "Dell", "DataBusWidth"),
                  "nic" => nil
                }
              end
              
              return pci_devices
            end
          rescue JSON::ParserError
            # Continue to fallback
          end
        end
        
        # Fallback for any version when all endpoints unavailable
        puts "PCI device information not available through standard or alternative endpoints" if @verbose
        return []
      end
    end

    # Map NICs to PCI bus IDs for Mellanox cards
    def nics_to_pci(nics, pci_devices)
      # Filter for Mellanox network controllers
      mellanox_pci = pci_devices.select do |dev| 
        dev['device_class'] =~ /NetworkController/ && dev['manufacturer'] =~ /Mellanox/
      end
      
      # Create mapping of NIC names to PCI IDs
      mapping = {}
      mellanox_pci.each do |dev|
        if dev['nic'] && dev['nic'] =~ /.*\/([^\/\-]+-\d+)/
          nic = $1  # e.g. NIC.Slot.1-1
          if dev['id'] =~ /^(\d+)-\d+-\d/
            pci_bus = $1  # e.g. 59
            mapping[nic] = pci_bus
          end
        end
      end
      
      # Add PCI bus info to each NIC port
      nics_with_pci = nics.map do |nic|
        nic_with_pci = nic.dup
        
        if nic_with_pci["ports"]
          nic_with_pci["ports"] = nic_with_pci["ports"].map do |port|
            port_with_pci = port.dup
            pci_bus = mapping[port["name"]]
            
            if pci_bus
              port_with_pci["pci"] = pci_bus
              port_with_pci["linux_device"] = "enp#{pci_bus}s0np0" # e.g. enp3s0np0
            end
            
            port_with_pci
          end
        end
        
        nic_with_pci
      end
      
      return nics_with_pci
    end

    # Kind of like a NIC, but serves a different purpose.
    def idrac_interface
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/iDRAC.Embedded.1%23NIC.1")
      idrac_data = JSON.parse(response.body)
      {
        "name"   => idrac_data["Id"],
        "status" => idrac_data.dig("Status", "Health") == 'OK' ? 'Up' : 'Down',
        "mac"    => idrac_data["MACAddress"],
        "mask"   => idrac_data["IPv4Addresses"].first["SubnetMask"],
        "ipv4"   => idrac_data["IPv4Addresses"].first["Address"],
        "origin" => idrac_data["IPv4Addresses"].first["AddressOrigin"], # DHCP or Static
        "port"   => nil,
        "speed_mbps" => idrac_data["SpeedMbps"],
        "kind"   => "ethernet"
      }
    end
    # Get system identification information
    def system_info
      response = authenticated_request(:get, "/redfish/v1")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Initialize return hash with defaults
          info = {
            "is_dell" => false,
            "is_ancient_dell" => false,
            "product" => data["Product"] || "Unknown",
            "service_tag" => nil,
            "model" => nil,
            "idrac_version" => data["RedfishVersion"],
            "firmware_version" => nil
          }
          
          # Check if it's a Dell iDRAC
          if data["Product"] == "Integrated Dell Remote Access Controller"
            info["is_dell"] = true
            
            # Get service tag from Dell OEM data
            info["service_tag"] = data.dig("Oem", "Dell", "ServiceTag")
            
            # Get firmware version - try both common locations
            info["firmware_version"] = data["FirmwareVersion"] || data.dig("Oem", "Dell", "FirmwareVersion")
            
            # Get additional system information
            system_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
            if system_response.status == 200
              system_data = JSON.parse(system_response.body)
              info["model"] = system_data["Model"]
            end
          
            return info
          else
            # Try to handle ancient Dell models where Product is null or non-standard
            if data["Product"].nil? || data.dig("Oem", "Dell")
              info["is_ancient_dell"] = true
              return info
            end
          end
          
          return info
        rescue JSON::ParserError
          raise Error, "Failed to parse system information: #{response.body}"
        end
      else
        raise Error, "Failed to get system information. Status code: #{response.status}"
      end
    end
    
    # Get processor/CPU information
    def cpus
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          summary = {
            "count" => data.dig("ProcessorSummary", "Count"),
            "model" => data.dig("ProcessorSummary", "Model"),
            "cores" => data.dig("ProcessorSummary", "CoreCount"),
            "threads" => data.dig("ProcessorSummary", "LogicalProcessorCount"),
            "status" => data.dig("ProcessorSummary", "Status", "Health")
          }
          
          return summary
        rescue JSON::ParserError
          raise Error, "Failed to parse processor information: #{response.body}"
        end
      else
        raise Error, "Failed to get processor information. Status code: #{response.status}"
      end
    end

    # Get system health status
    def system_health
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          health = {
            "overall" => data.dig("Status", "HealthRollup"),
            "system" => data.dig("Status", "Health"),
            "processor" => data.dig("ProcessorSummary", "Status", "Health"),
            "memory" => data.dig("MemorySummary", "Status", "Health"),
            "storage" => data.dig("Storage", "Status", "Health")
          }
          
          return health
        rescue JSON::ParserError
          raise Error, "Failed to parse system health information: #{response.body}"
        end
      else
        raise Error, "Failed to get system health. Status code: #{response.status}"
      end
    end

    # Get system event logs
    def system_event_logs
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/Logs/Sel?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          logs = data["Members"].map do |log|
            puts "#{log['Id']} : #{log['Created']} : #{log['Message']} : #{log['Severity']}".yellow
            log
          end
          
          # Sort by creation date, newest first
          return logs.sort_by { |log| log['Created'] }.reverse
        rescue JSON::ParserError
          raise Error, "Failed to parse system event logs response: #{response.body}"
        end
      else
        raise Error, "Failed to get system event logs. Status code: #{response.status}"
      end
    end

    # Clear system event logs
    def clear_system_event_logs
      response = authenticated_request(
        :post, 
        "/redfish/v1/Managers/iDRAC.Embedded.1/LogServices/Sel/Actions/LogService.ClearLog",
        body: {}.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      if response.status.between?(200, 299)
        puts "System Event Logs cleared".green
        return true
      else
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

    # Get total memory in human-readable format
    def total_memory_human(memory_data)
      total_memory = memory_data.sum { |m| m.capacity_bytes }
      "%0.2f GB" % (total_memory.to_f / 1.gigabyte)
    end

    # Get complete system configuration
    def get_system_config
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$expand=*($levels=1)")
      
      if response.status == 200
        return JSON.parse(response.body)
      else
        raise Error, "Failed to retrieve system configuration: #{response.status}"
      end
    end
    
    # Get system summary information (used by CLI summary command)
    def get_system_summary
      # Get system information
      system_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      system_info = JSON.parse(system_response.body)
      
      # Get iDRAC information
      idrac_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1")
      idrac_info = JSON.parse(idrac_response.body)
      
      # Get network information
      network_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/NIC.1")
      network_info = JSON.parse(network_response.body)
      
      # Initialize license_type to Unknown
      license_type = "Unknown"
      license_description = nil
      
      # Try to get license information using DMTF standard method
      begin
        license_response = authenticated_request(:get, "/redfish/v1/LicenseService/Licenses")
        license_info = JSON.parse(license_response.body)
        
        # Extract license type if licenses are found
        if license_info["Members"] && !license_info["Members"].empty?
          license_entry_response = authenticated_request(:get, license_info["Members"][0]["@odata.id"])
          license_entry = JSON.parse(license_entry_response.body)
          
          # Get license type from EntitlementId or LicenseType
          if license_entry["EntitlementId"] && license_entry["EntitlementId"].include?("Enterprise")
            license_type = "Enterprise"
          elsif license_entry["LicenseType"]
            license_type = license_entry["LicenseType"]
          end
          
          # Get license description if available
          license_description = license_entry["Description"] if license_entry["Description"]
        end
      rescue => e
        # If DMTF method fails, try Dell OEM method
        begin
          dell_license_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLicenses")
          dell_license_info = JSON.parse(dell_license_response.body)
          
          # Extract license type if licenses are found
          if dell_license_info["Members"] && !dell_license_info["Members"].empty?
            dell_license_entry_response = authenticated_request(:get, dell_license_info["Members"][0]["@odata.id"])
            dell_license_entry = JSON.parse(dell_license_entry_response.body)
            
            # Get license type from LicenseType or Description
            if dell_license_entry["LicenseType"]
              license_type = dell_license_entry["LicenseType"]
            elsif dell_license_entry["Description"] && dell_license_entry["Description"].include?("Enterprise")
              license_type = "Enterprise"
            end
            
            # Get license description if available
            license_description = dell_license_entry["Description"] if dell_license_entry["Description"]
          end
        rescue => e2
          # License information not available
        end
      end
      
      # Format the license display string
      license_display = license_type
      if license_description
        license_display = "#{license_type} (#{license_description})"
      end

      # Return the system summary
      {
        power_state: system_info["PowerState"],
        model: system_info["Model"],
        host_name: system_info["HostName"],
        operating_system: system_info.dig("Oem", "Dell", "OperatingSystem"),
        os_version: system_info.dig("Oem", "Dell", "OperatingSystemVersion"),
        service_tag: system_info["SKU"],
        bios_version: system_info.dig("BiosVersion"),
        idrac_firmware: idrac_info.dig("FirmwareVersion"),
        ip_address: network_info.dig("IPv4Addresses", 0, "Address"),
        mac_address: network_info.dig("MACAddress"),
        license: license_display
      }
    end
    
    # Get basic system information (used for test_live function)
    def get_basic_system_info
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if response.status == 200
        data = JSON.parse(response.body)
        return {
          model: data["Model"],
          sku: data["SKU"]
        }
      else
        raise Error, "Failed to get basic system information: #{response.status}"
      end
    end
  end
end 