require 'json'
require 'colorize'
require 'recursive-open-struct'

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
            bank, index = /DIMM ([A-Z])(\d+)/.match(dimm_name).captures rescue [nil, nil]
            
            puts "DIMM: #{m["Model"]} #{m["Name"]} > #{m["CapacityMiB"]}MiB > #{m["Status"]["Health"]} > #{m["OperatingSpeedMhz"]}MHz > #{m["PartNumber"]} / #{m["SerialNumber"]}"
            
            memory_data = { 
              model: m["Model"], 
              name: m["Name"], 
              capacity_bytes: m["CapacityMiB"].to_i.megabyte, 
              health: m["Status"]["Health"] ? m["Status"]["Health"] : "N/A", 
              speed_mhz: m["OperatingSpeedMhz"], 
              part_number: m["PartNumber"], 
              serial: m["SerialNumber"],
              bank: bank,
              index: index.to_i
            }
            
            RecursiveOpenStruct.new(memory_data, recurse_over_arrays: true)
          end
          
          return memory.sort_by { |m| [m.bank || "Z", m.index || 999] }
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
            puts "PSU: #{psu["Name"]} > #{psu["PowerInputWatts"]}W > #{psu["Status"]["Health"]}"
            psu_data = { 
              name: psu["Name"], 
              voltage: psu["LineInputVoltage"], 
              voltage_human: psu["LineInputVoltageType"], # AC240V
              watts: psu["PowerInputWatts"],
              part: psu["PartNumber"],
              model: psu["Model"],
              serial: psu["SerialNumber"],
              status: psu["Status"]["Health"],
            }
            
            RecursiveOpenStruct.new(psu_data, recurse_over_arrays: true)
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
              puts "Fan: #{fan["Name"]} > #{fan["Reading"]} > #{fan["Status"]["Health"]}"
              fan_data = { 
                name: fan["Name"], 
                rpm: fan["Reading"],
                serial: fan["SerialNumber"],
                status: fan["Status"]["Health"]
              }
              
              RecursiveOpenStruct.new(fan_data, recurse_over_arrays: true)
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
            "status" => data["Status"]["Health"] == 'OK' ? 'Up' : 'Down',
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
              device_class: pcie_function ? pcie_function["DeviceClass"] : nil,
              manufacturer: manufacturer,
              name: stub["Name"],
              description: stub["Description"],
              id: pcie_function ? pcie_function["Id"] : stub["Id"],
              slot_type: pcie_function ? pcie_function.dig("Oem", "Dell", "DellPCIeFunction", "SlotType") : nil,
              bus_width: pcie_function ? pcie_function.dig("Oem", "Dell", "DellPCIeFunction", "DataBusWidth") : nil,
              nic: pcie_function ? pcie_function.dig("Links", "EthernetInterfaces", 0, "@odata.id") : nil
            }
            
            puts "PCI Device: #{device_info[:name]} > #{device_info[:manufacturer]} > #{device_info[:device_class]} > #{device_info[:description]} > #{device_info[:id]}"
            
            device_info
          end
          
          return pci
        rescue JSON::ParserError
          raise Error, "Failed to parse PCI devices response: #{response.body}"
        end
      else
        raise Error, "Failed to get PCI devices. Status code: #{response.status}"
      end
    end

    # Map NICs to PCI bus IDs for Mellanox cards
    def nics_to_pci(nics, pci_devices)
      # Filter for Mellanox network controllers
      mellanox_pci = pci_devices.select do |dev| 
        dev[:device_class] =~ /NetworkController/ && dev[:manufacturer] =~ /Mellanox/
      end
      
      # Create mapping of NIC names to PCI IDs
      mapping = {}
      mellanox_pci.each do |dev|
        if dev[:nic] && dev[:nic] =~ /.*\/([^\/\-]+-\d+)/
          nic = $1  # e.g. NIC.Slot.1-1
          if dev[:id] =~ /^(\d+)-\d+-\d/
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
  end
end 