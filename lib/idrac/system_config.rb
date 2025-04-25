require 'json'
require 'colorize'

module IDRAC
  module SystemConfig
    # Get the system configuration profile for a given target (e.g. "RAID")
    def get_system_configuration_profile(target: "RAID")
      tries = 0
      location = nil
      started_at = Time.now
      
      while location.nil?
        debug "Exporting System Configuration try #{tries+=1}..."
        
        response = authenticated_request(:post, 
          "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ExportSystemConfiguration", 
          body: {"ExportFormat": "JSON", "ShareParameters":{"Target": target}}.to_json,
          headers: {"Content-Type" => "application/json"}
        )

        if response.status == 400
          debug "Failed exporting system configuration: #{response.body}", 1, :red
          raise Error, "Failed exporting system configuration profile"
        elsif response.status.between?(401, 599)
          debug "Failed exporting system configuration: #{response.body}", 1, :red
          
          # Parse error response
          error_data = JSON.parse(response.body) rescue nil
          
          if error_data && error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
            message_info = error_data["error"]["@Message.ExtendedInfo"]
            
            # Check for specific error conditions
            if message_info.any? { |m| m["Message"] =~ /existing configuration job is already in progress/ }
              debug "Existing configuration job is already in progress, retrying...", 1, :yellow
              sleep 30
            elsif message_info.any? { |m| m["Message"] =~ /job operation is already running/ }
              debug "Existing job operation is already in progress, retrying...", 1, :yellow
              sleep 60
            else
              # Detailed error info for debugging
              debug "*" * 80, 1, :red
              debug "Headers: #{response.headers.inspect}", 1, :red
              debug "Body: #{response.body}", 1, :yellow
              
              # Extract the first error message if available
              error_message = message_info.first["Message"] rescue "Unknown error"
              debug "Error: #{error_message}", 1, :red
              
              raise Error, "Failed to export SCP: #{error_message}"
            end
          else
            raise Error, "Failed to export SCP with status #{response.status}"
          end
        else
          # Success path - extract location header
          location = response.headers["location"]
          
          if location.nil? || location.empty?
            raise Error, "Empty location header in response: #{response.headers.inspect}"
          end
        end

        # Progress reporting
        minutes_elapsed = ((Time.now - started_at).to_f / 60).to_i
        debug "Waiting for export to complete... #{minutes_elapsed} minutes", 1, :yellow
        
        # Exponential backoff
        sleep 2**[tries, 6].min # Cap at 64 seconds
        
        if tries > 10
          raise Error, "Failed exporting SCP after #{tries} tries, location: #{location}"
        end
      end

      # Extract job ID from location
      job_id = location.split("/").last
      
      # Poll for job completion
      job_complete = false
      scp = nil
      
      while !job_complete
        job_response = authenticated_request(:get, "/redfish/v1/TaskService/Tasks/#{job_id}")
        
        if job_response.status == 200
          job_data = JSON.parse(job_response.body)
          
          if ["Running", "Pending", "New"].include?(job_data["TaskState"])
            debug "Job status: #{job_data["TaskState"]}, waiting...", 2
            sleep 3
          else
            job_complete = true
            scp = job_data
            
            # Verify we have the system configuration data
            unless scp["SystemConfiguration"]
              raise Error, "Failed exporting SCP, taskstate: #{scp["TaskState"]}, taskstatus: #{scp["TaskStatus"]}"
            end
          end
        else
          raise Error, "Failed to check job status: #{job_response.status} - #{job_response.body}"
        end
      end
      
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
      
      # Get the job location
      job_location = response.headers["location"]
      if job_location.nil? || job_location.empty?
        debug response.inspect, 1, :blue
        return { status: :failed, error: "Failed importing SCP... invalid iDRAC response" }
      end
      
      # Extract job ID and monitor the task
      job_id = job_location.split("/").last
      task = nil
      
      begin
        loop do
          task_response = authenticated_request(:get, "/redfish/v1/TaskService/Tasks/#{job_id}")
          
          if task_response.status == 200
            task = JSON.parse(task_response.body)
            
            if task["TaskState"] != "Running"
              break
            end
            
            debug "Waiting for task to complete...: #{task["TaskState"]} #{task["TaskStatus"]}", 1
            sleep 5
          else
            return { 
              status: :failed, 
              error: "Failed to check task status: #{task_response.status} - #{task_response.body}" 
            }
          end
        end
        
        # Check final task state
        if task["TaskState"] == "Completed" && task["TaskStatus"] == "OK"
          return { status: :success }
        else
          # For debugging purposes
          debug task.inspect, 1, :yellow
          
          # Extract any messages from the response
          messages = []
          if task["Messages"] && task["Messages"].is_a?(Array)
            messages = task["Messages"].map { |m| m["Message"] }.compact
          end
          
          return { 
            status: :failed, 
            task_state: task["TaskState"], 
            task_status: task["TaskStatus"],
            messages: messages,
            error: messages.first || "Task failed with state: #{task["TaskState"]}"
          }
        end
      rescue => e
        return { status: :error, error: "Exception monitoring task: #{e.message}" }
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