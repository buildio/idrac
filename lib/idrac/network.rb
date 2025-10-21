# frozen_string_literal: true

require 'json'

module IDRAC
  module Network
    # Get iDRAC version information following Dell's approach
    def get_idrac_version_info
      # Get iDRAC model to determine generation (following Dell's pattern)
      manager_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1?$select=Model,FirmwareVersion")
      
      if manager_response.status == 200
        manager_data = JSON.parse(manager_response.body)
        model = manager_data["Model"]
        firmware_version = manager_data["FirmwareVersion"]
        
        # Determine iDRAC generation based on model (Dell's approach)
        if model.include?("12") || model.include?("13")
          idrac_generation = 8
        elsif model.include?("14") || model.include?("15") || model.include?("16")
          idrac_generation = 9
        else
          idrac_generation = 10  # iDRAC9 and newer
        end
        
        # Convert firmware version to numeric for comparison (Dell's approach)
        firmware_numeric = firmware_version.gsub(".", "").to_i if firmware_version
        
        {
          generation: idrac_generation,
          firmware_version: firmware_version,
          firmware_numeric: firmware_numeric,
          model: model
        }
      else
        # Fallback - assume newer version if we can't determine
        { generation: 9, firmware_version: "unknown", firmware_numeric: 0, model: "unknown" }
      end
    end
    
    def get_bmc_network
      # Get the iDRAC ethernet interface
      collection_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces")
      
      if collection_response.status == 200
        collection = JSON.parse(collection_response.body)
        
        if collection["Members"] && collection["Members"].any?
          interface_path = collection["Members"][0]["@odata.id"]
          response = authenticated_request(:get, interface_path)
          
          if response.status == 200
            data = JSON.parse(response.body)
            {
              "ipv4" => data.dig("IPv4Addresses", 0, "Address"),
              "mask" => data.dig("IPv4Addresses", 0, "SubnetMask"),
              "gateway" => data.dig("IPv4Addresses", 0, "Gateway"),
              "mode" => data.dig("IPv4Addresses", 0, "AddressOrigin"), # DHCP or Static
              "mac" => data["MACAddress"],
              "hostname" => data["HostName"],
              "fqdn" => data["FQDN"],
              "dns_servers" => data["NameServers"] || [],
              "name" => data["Id"] || "iDRAC",
              "speed_mbps" => data["SpeedMbps"] || 1000,
              "status" => data.dig("Status", "Health") || "OK",
              "kind" => "ethernet"
            }
          else
            raise Error, "Failed to get interface details. Status: #{response.status}"
          end
        else
          raise Error, "No ethernet interfaces found"
        end
      else
        raise Error, "Failed to get ethernet interfaces. Status: #{collection_response.status}"
      end
    end
    
    def set_bmc_network(ipv4: nil, mask: nil, gateway: nil, 
                        dns_primary: nil, dns_secondary: nil, hostname: nil, 
                        dhcp: false)
      puts "🔧 iDRAC set_bmc_network called with: ipv4=#{ipv4}, mask=#{mask}, gateway=#{gateway}, dhcp=#{dhcp}".cyan
      
      # Get iDRAC version information first (following Dell's approach)
      begin
        puts "🔍 Getting iDRAC version information...".yellow
        version_info = get_idrac_version_info
        puts "✅ Detected iDRAC Generation #{version_info[:generation]}, Firmware: #{version_info[:firmware_version]}".green
        puts "   Model: #{version_info[:model]}, Firmware Numeric: #{version_info[:firmware_numeric]}".cyan
      rescue => e
        puts "❌ Error getting iDRAC version info: #{e.class} - #{e.message}".red
        raise e
      end
      
      # Get the interface path
      puts "🔍 Getting ethernet interfaces collection...".yellow
      collection_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces")
      
      if collection_response.status == 200
        puts "✅ Got ethernet interfaces collection successfully".green
        collection = JSON.parse(collection_response.body)
        puts "🔍 Collection members: #{collection["Members"]&.size || 0} interfaces found".cyan
        
        if collection["Members"] && collection["Members"].any?
          interface_path = collection["Members"][0]["@odata.id"]
          puts "✅ Using interface path: #{interface_path}".green
          
          if dhcp
            puts "Setting iDRAC to DHCP mode...".yellow
            body = {
              "DHCPv4" => {
                "DHCPEnabled" => true
              }
            }
          else
            puts "Configuring iDRAC network settings...".yellow
            body = {}
            
            # Choose API approach based on iDRAC generation and firmware version
            if version_info[:generation] >= 9 && version_info[:firmware_numeric] > 0
              # iDRAC9/10 - use System Configuration Profile (SCP) approach for reliable network changes
              puts "Using iDRAC9+ SCP approach for network configuration".yellow
              puts "  Delegating to set_idrac_ip method for reliable configuration".cyan
              
              # Use the existing set_idrac_ip method which uses SCP
              return set_idrac_ip(new_ip: ipv4, new_gw: gateway, new_nm: mask)
              
            else
              # iDRAC8 or older firmware - use IPv4Addresses approach
              puts "Using legacy iDRAC8 API approach (IPv4Addresses)".yellow
              
              # Disable DHCP first for older versions
              body["DHCPv4"] = {
                "DHCPEnabled" => false
              }
              
              # Configure static IP using legacy API
              if ipv4 && mask
                body["IPv4Addresses"] = [{
                  "Address" => ipv4,
                  "SubnetMask" => mask,
                  "Gateway" => gateway,
                  "AddressOrigin" => "Static"
                }]
                puts "  IP: #{ipv4}/#{mask}".cyan
                puts "  Gateway: #{gateway}".cyan if gateway
              end
            end
            
            # Configure DNS if provided
            if dns_primary || dns_secondary
              dns_servers = []
              dns_servers << dns_primary if dns_primary
              dns_servers << dns_secondary if dns_secondary
              body["StaticNameServers"] = dns_servers
              puts "  DNS: #{dns_servers.join(', ')}".cyan
            end
            
            # Configure hostname if provided
            if hostname
              body["HostName"] = hostname
              puts "  Hostname: #{hostname}".cyan
            end
          end
          
          # Send the request using the version-specific approach
          puts "🔍 Sending PATCH request to #{interface_path}".yellow
          puts "📦 Request body: #{JSON.pretty_generate(body)}".cyan
          
          begin
            response = authenticated_request(
              :patch,
              interface_path,
              body: body.to_json
            )
            puts "✅ Got response with status: #{response.status}".green
          rescue => e
            puts "❌ Error sending PATCH request: #{e.class} - #{e.message}".red
            raise e
          end
          
          if response.status.between?(200, 299)
            puts "iDRAC network configured successfully using #{version_info[:generation] >= 9 ? 'newer' : 'legacy'} API.".green
            
            # For network configuration changes, automatically restart iDRAC to apply settings
            if ipv4 && !dhcp
              puts "Initiating iDRAC restart to apply network configuration...".yellow
              restart_response = authenticated_request(
                :post,
                "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset",
                body: { "ResetType" => "GracefulRestart" }.to_json
              )
              
              if restart_response.status == 204
                puts "✓ iDRAC restart initiated successfully.".green
                puts "Network configuration will be applied after restart (2-3 minutes).".cyan
                puts "New IP: #{ipv4}".cyan
              else
                puts "⚠ iDRAC restart failed (#{restart_response.status}). You may need to restart manually.".yellow
                puts "Configuration is saved but may not be active until restart.".yellow
              end
            else
              puts "WARNING: iDRAC may restart network services. Connection may be lost.".yellow
            end
            
            puts "✅ Returning true from set_bmc_network".green
            true
          else
            # Log the error with version context for troubleshooting
            puts "❌ Network configuration failed with status: #{response.status}".red
            puts "🔍 Response body: #{response.body}".red
            error_msg = "Failed to configure iDRAC network (Generation #{version_info[:generation]}, FW #{version_info[:firmware_version]}): #{response.status} - #{response.body}"
            raise Error, error_msg
          end
        else
          puts "❌ No ethernet interfaces found in collection".red
          raise Error, "No ethernet interfaces found"
        end
      else
        puts "❌ Failed to get ethernet interfaces collection, status: #{collection_response.status}".red
        puts "🔍 Response body: #{collection_response.body}".red
        raise Error, "Failed to get ethernet interfaces"
      end
    end
    
    def set_bmc_dhcp
      # Convenience method
      set_bmc_network(dhcp: true)
    end
  end
end