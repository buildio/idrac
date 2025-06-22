require 'json'
require 'colorize'

module IDRAC
  module SystemConfig
    # This assigns the iDRAC IP to be a STATIC IP.
    def set_idrac_ip(new_ip:, new_gw:, new_nm:, vnc_password: "calvin")
      scp = get_system_configuration_profile(target: "iDRAC")
      pp scp
      ## We want to access the iDRAC web server even when IPs don't match (and they won't when we port forward local host):
      set_scp_attribute(scp, "WebServer.1#HostHeaderCheck", "Disabled")
      ## We want VirtualMedia to be enabled so we can mount ISOs: set_scp_attribute(scp, "VirtualMedia.1#Enable", "Enabled")
      set_scp_attribute(scp, "VirtualMedia.1#EncryptEnable", "Disabled")
      ## We want to access VNC Server on 5901 for screenshots and without SSL:
      set_scp_attribute(scp, "VNCServer.1#Enable", "Enabled")
      set_scp_attribute(scp, "VNCServer.1#Port", "5901")
      set_scp_attribute(scp, "VNCServer.1#SSLEncryptionBitLength", "Disabled")
      # And password calvin
      set_scp_attribute(scp, "VNCServer.1#Password", vnc_password)
      # Disable DHCP on management NIC
      set_scp_attribute(scp, "IPv4.1#DHCPEnable", "Disabled")
      if drac_license_version.to_i == 8
        # We want to use HTML for the virtual console
        set_scp_attribute(scp, "VirtualConsole.1#PluginType", "HTML5")
        # We want static IP for the iDRAC
        set_scp_attribute(scp, "IPv4.1#Address", new_ip)
        set_scp_attribute(scp, "IPv4.1#Gateway", new_gw)
        set_scp_attribute(scp, "IPv4.1#Netmask", new_nm)
      elsif drac_license_version.to_i == 9
        # We want static IP for the iDRAC
        set_scp_attribute(scp, "IPv4Static.1#Address", new_ip)
        set_scp_attribute(scp, "IPv4Static.1#Gateway", new_gw)
        set_scp_attribute(scp, "IPv4Static.1#Netmask", new_nm)
        # {"Name"=>"SerialCapture.1#Enable", "Value"=>"Disabled", "Set On Import"=>"True", "Comment"=>"Read and Write"},
      else
        raise "Unknown iDRAC version"
      end
      while true
        res = self.post(path: "Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration", params: {"ImportBuffer": scp.to_json, "ShareParameters": {"Target": "iDRAC"}})
        # A successful JOB will have a location header with a job id.
        # We can get a busy message instead if we've sent too many iDRAC jobs back-to-back, so we check for that here.
        if res[:headers]["location"].present?
          # We have a job id, so we're good to go.
          break
        else
          # Depending on iDRAC version content-length may be present or not.
          # res[:headers]["content-length"].blank?
          msg = res['body']['error']['@Message.ExtendedInfo'].first['Message']
          details = res['body']['error']['@Message.ExtendedInfo'].first['Resolution']
          # msg     => "A job operation is already running. Retry the operation after the existing job is completed."
          # details => "Wait until the running job is completed or delete the scheduled job and retry the operation."
          if details =~ /Wait until the running job is completed/
            sleep 10
          else
            Rails.logger.warn msg+details
            raise "failed configuring static ip, message: #{msg}, details: #{details}"
          end
        end
      end
      
      # Allow some time for the iDRAC to prepare before checking the task status
      sleep 3
      
      # Use handle_location to monitor task progress
      result = handle_location(res[:headers]["location"])
      
      # Check if the operation succeeded
      if result[:status] != :success
        # Extract error details if available
        message = result[:messages].first rescue "N/A" 
        error = result[:error] || "Unknown error"
        raise "Failed configuring static IP: #{message} - #{error}"
      end
      
      # Finally, let's update our configuration to reflect the new port:
      self.idrac
      return true
    end



    # Get the system configuration profile for a given target (e.g. "RAID")
    def get_system_configuration_profile(target: "RAID")
      debug "Exporting System Configuration..."
      response = authenticated_request(:post, 
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ExportSystemConfiguration", 
        body: {"ExportFormat": "JSON", "ShareParameters":{"Target": target}}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
      scp = handle_location(response.headers["location"]) 
      # We experienced this with older iDRACs, so let's give a enriched error to help debug.
      raise(Error, "Failed exporting SCP, no location header found in response. Response: #{response.inspect}") if scp.nil?
      raise(Error, "Failed exporting SCP, taskstate: #{scp["TaskState"]}, taskstatus: #{scp["TaskStatus"]}") unless scp["SystemConfiguration"]
      return scp
    end

    # Set an attribute in a system configuration profile
    def set_scp_attribute(scp, name, value)
      # Make a deep copy to avoid modifying the original
      scp_copy = JSON.parse(scp.to_json)
      
      # Clear unrelated attributes for quicker transfer
      scp_copy["SystemConfiguration"].delete("Comments")
      scp_copy["SystemConfiguration"].delete("TimeStamp")
      scp_copy["SystemConfiguration"].delete("ServiceTag")
      scp_copy["SystemConfiguration"].delete("Model")

      # Skip these attribute groups to make the transfer faster
      excluded_prefixes = [
        "User", "Telemetry", "SecurityCertificate", "AutoUpdate", "PCIe", "LDAP", "ADGroup", "ActiveDirectory",
        "IPMILan", "EmailAlert", "SNMP", "IPBlocking", "IPMI", "Security", "RFS", "OS-BMC", "SupportAssist",
        "Redfish", "RedfishEventing", "Autodiscovery", "SEKM-LKC", "Telco-EdgeServer", "8021XSecurity", "SPDM",
        "InventoryHash", "RSASecurID2FA", "USB", "NIC", "IPv6", "NTP", "Logging", "IOIDOpt", "SSHCrypto",
        "RemoteHosts", "SysLog", "Time", "SmartCard", "ACME", "ServiceModule", "Lockdown",
        "DefaultCredentialMitigation", "AutoOSLockGroup", "LocalSecurity", "IntegratedDatacenter",
        "SecureDefaultPassword.1#ForceChangePassword", "SwitchConnectionView.1#Enable", "GroupManager.1",
        "ASRConfig.1#Enable", "SerialCapture.1#Enable", "CertificateManagement.1",
        "Update", "SSH", "SysInfo", "GUI"
      ]
      
      # Remove excluded attribute groups
      if scp_copy["SystemConfiguration"]["Components"] && 
         scp_copy["SystemConfiguration"]["Components"][0] && 
         scp_copy["SystemConfiguration"]["Components"][0]["Attributes"]
        
        attrs = scp_copy["SystemConfiguration"]["Components"][0]["Attributes"]
        
        attrs.reject! do |attr|
          excluded_prefixes.any? { |prefix| attr["Name"] =~ /\A#{prefix}/ }
        end
        
        # Update or add the specified attribute
        if attrs.find { |a| a["Name"] == name }.nil?
          # Attribute doesn't exist, create it
          attrs << { "Name" => name, "Value" => value, "Set On Import" => "True" }
        else
          # Update existing attribute
          attrs.find { |a| a["Name"] == name }["Value"] = value
          attrs.find { |a| a["Name"] == name }["Set On Import"] = "True"
        end
        
        scp_copy["SystemConfiguration"]["Components"][0]["Attributes"] = attrs
      end
      
      return scp_copy
    end

    # Helper method to normalize enabled/disabled values
    def normalize_enabled_value(v)
      return "Disabled" if v.nil? || v == false
      return "Enabled"  if v == true
      
      raise Error, "Invalid value for normalize_enabled_value: #{v}" unless v.is_a?(String)
      
      if v.strip.downcase == "enabled"
        return "Enabled"
      else
        return "Disabled"
      end
    end

    # Apply a system configuration profile to the iDRAC
    def set_system_configuration_profile(scp, target: "ALL", reboot: false, retry_count: 0)
      # Ensure scp has the proper structure with SystemConfiguration wrapper
      scp_to_apply = if scp.is_a?(Hash) && scp["SystemConfiguration"]
        scp
      else
        # Ensure scp is an array of components
        components = scp.is_a?(Array) ? scp : [scp]
        { "SystemConfiguration" => { "Components" => components } }
      end

      # Create the import parameters
      params = { 
        "ImportBuffer" => JSON.pretty_generate(scp_to_apply),
        "ShareParameters" => {"Target" => target},
        "ShutdownType" => "Forced",
        "HostPowerState" => reboot ? "On" : "Off"
      }
      
      debug "Importing System Configuration...", 1, :blue
      debug "Configuration: #{JSON.pretty_generate(scp_to_apply)}", 3
      
      # Make the API request
      response = authenticated_request(
        :post, 
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration",
        body: params.to_json,
        headers: {"Content-Type" => "application/json"}
      )
      
      # Check for immediate errors
      if response.headers["content-length"].to_i > 0
        debug response.inspect, 1, :red
        return { status: :failed, error: "Failed importing SCP: #{response.body}" }
      end
      
      return handle_location(response.headers["location"])
    end

    # This puts the SCP into a format that can be used by reasonable Ruby code.
    # It's a hash of FQDDs to attributes.
    def usable_scp(scp)
      # { "FQDD1" => { "Name" => "Value" }, "FQDD2" => { "Name" => "Value" } }
      scp.dig("SystemConfiguration", "Components").inject({}) do |acc, component|
        fqdd = component["FQDD"]
        attributes = component["Attributes"]
        acc[fqdd] = attributes.inject({}) do |attr_acc, attr|
          attr_acc[attr["Name"]] = attr["Value"]
          attr_acc
        end
        acc
      end
    end

    # Helper method to create an SCP component with the specified FQDD and attributes
    def make_scp(fqdd:, components: [], attributes: {})
      com = []
      att = []
      
      # Process components
      components.each do |component|
        com << component
      end
      
      # Process attributes
      attributes.each do |k, v|
        if v.is_a?(Array)
          v.each do |value|
            att << { "Name" => k, "Value" => value, "Set On Import" => "True" }
          end
        elsif v.is_a?(Integer)
          # Convert integers to strings
          att << { "Name" => k, "Value" => v.to_s, "Set On Import" => "True" }
        elsif v.is_a?(Hash)
          # Handle nested components
          v.each do |kk, vv|
            com += make_scp(fqdd: kk, attributes: vv)
          end
        else
          att << { "Name" => k, "Value" => v, "Set On Import" => "True" }
        end
      end
      
      # Build the final component
      bundle = { "FQDD" => fqdd }
      bundle["Components"] = com if com.any?
      bundle["Attributes"] = att if att.any?
      
      return bundle
    end

    # Convert an SCP array to a hash for easier manipulation
    def scp_to_hash(scp)
      scp.inject({}) do |acc, component|
        acc[component["FQDD"]] = component["Attributes"]
        acc
      end
    end

    # Convert an SCP hash back to array format
    def hash_to_scp(hash)
      hash.inject([]) do |acc, (fqdd, attributes)|
        acc << { "FQDD" => fqdd, "Attributes" => attributes }
        acc
      end
    end

    # Merge two SCPs together
    def merge_scp(scp1, scp2)
      return scp1 || scp2 unless scp1 && scp2 # Return the one that's not nil if either is nil
      
      # Make them both arrays in case they aren't
      scp1_array = scp1.is_a?(Array) ? scp1 : [scp1]
      scp2_array = scp2.is_a?(Array) ? scp2 : [scp2]
      
      # Convert to hashes for merging
      hash1 = scp_to_hash(scp1_array)
      hash2 = scp_to_hash(scp2_array)
      
      # Perform deep merge
      merged = deep_merge(hash1, hash2)
      
      # Convert back to SCP array format
      hash_to_scp(merged)
    end

    private

    # Helper method for deep merging of hashes
    def deep_merge(hash1, hash2)
      result = hash1.dup
      
      hash2.each do |key, value|
        if result[key].is_a?(Array) && value.is_a?(Array)
          # For arrays of attributes, merge by name
          existing_names = result[key].map { |attr| attr["Name"] }
          
          value.each do |attr|
            if existing_index = existing_names.index(attr["Name"])
              # Update existing attribute
              result[key][existing_index] = attr
            else
              # Add new attribute
              result[key] << attr
            end
          end
        else
          # For other values, just replace
          result[key] = value
        end
      end
      
      result
    end
  end
end 
