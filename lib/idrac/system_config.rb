require 'json'
require 'colorize'

module IDRAC
  module SystemConfig
    # This assigns the iDRAC IP to be a STATIC IP.
    def set_idrac_ip(new_ip:, new_gw:, new_nm:, vnc_password: "calvin", vnc_port: 5901)
      # Cache license version to avoid multiple iDRAC calls
      version = license_version.to_i
      
      case version
      when 8
        ipv4_prefix = "IPv4"
        settings = { "VirtualConsole.1#PluginType" => "HTML5" }
      when 9
        ipv4_prefix = "IPv4Static"
        settings = {}
      else
        raise Error, "Unsupported iDRAC version: #{version}. Supported versions: 8, 9"
      end
      
      # Build base settings for all versions
      settings.merge!({
        "WebServer.1#HostHeaderCheck" => "Disabled",
        "VirtualMedia.1#EncryptEnable" => "Disabled", 
        "VNCServer.1#Enable" => "Enabled",
        "VNCServer.1#Port" => vnc_port.to_s,
        "VNCServer.1#SSLEncryptionBitLength" => "Disabled",
        "VNCServer.1#Password" => vnc_password,
        "IPv4.1#DHCPEnable" => "Disabled", # only applies to iDRAC 8
        "#{ipv4_prefix}.1#Address" => new_ip, # only applies to iDRAC 9
        "#{ipv4_prefix}.1#Gateway" => new_gw,
        "#{ipv4_prefix}.1#Netmask" => new_nm
      })
      
      # Build SCP from scratch instead of getting full profile
      scp_component = make_scp(fqdd: "iDRAC.Embedded.1", attributes: settings)
      scp = { "SystemConfiguration" => { "Components" => [scp_component] } }
      
      # Submit configuration with job availability handling
      res = wait_for_job_availability do
        authenticated_request(:post,
          "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration",
          body: {"ImportBuffer": scp.to_json, "ShareParameters": {"Target": "iDRAC"}}.to_json
        )
      end
      
      sleep 3  # Allow iDRAC to prepare
      result = handle_location_with_ip_change(res.headers["location"], new_ip)
      
      raise "Failed configuring static IP: #{result[:messages]&.first || result[:error] || "Unknown error"}" if result[:status] != :success
      true
    end



    # Get the system configuration profile for a given target (e.g. "RAID")
    def get_system_configuration_profile(target: "RAID")
      debug "Exporting System Configuration..."
      response = authenticated_request(:post,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ExportSystemConfiguration",
        body: {"ExportFormat": "JSON", "ShareParameters":{"Target": target}}.to_json
      )
      scp = handle_location(response.headers["location"]) 
      # We experienced this with older iDRACs, so let's give a enriched error to help debug.
      raise(Error, "Failed exporting SCP, no location header found in response. Response: #{response.inspect}") if scp.nil?
      raise(Error, "Failed exporting SCP, taskstate: #{scp["TaskState"]}, taskstatus: #{scp["TaskStatus"]}") unless scp["SystemConfiguration"]
      return scp
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
      
      # Validate the SCP structure before sending
      unless scp_to_apply.is_a?(Hash) && scp_to_apply["SystemConfiguration"] && scp_to_apply["SystemConfiguration"]["Components"]
        raise ArgumentError, "Invalid SCP structure: must contain SystemConfiguration.Components"
      end

      # Create the import parameters
      # Use compact JSON generation to avoid formatting issues with Dell iDRAC
      params = { 
        "ImportBuffer" => JSON.generate(scp_to_apply),
        "ShareParameters" => {"Target" => target},
        "ShutdownType" => "Forced",
        "HostPowerState" => reboot ? "On" : "Off"
      }
      
      debug "Importing System Configuration...", 1, :blue
      debug "Configuration: #{JSON.pretty_generate(scp_to_apply)}", 1, :cyan
      debug "ImportBuffer content: #{params['ImportBuffer']}", 1, :yellow
      
      # Make the API request
      response = authenticated_request(
        :post,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration",
        body: params.to_json
      )
      
      # Check for immediate errors
      if response.headers["content-length"].to_i > 0
        debug response.inspect, 1, :red
        error_message = "Failed importing SCP: #{response.body}"
        
        # Check for specific schema validation errors
        if response.body.include?("invalid characters") || response.body.include?("invalid token")
          error_message += "\nThis may be due to JSON formatting issues. The SCP structure might contain characters not accepted by Dell iDRAC."
        elsif response.body.include?("not compliant with configuration schema")
          error_message += "\nThe SCP structure does not match Dell's expected schema format."
        end
        
        return { status: :failed, error: error_message }
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
        # Convert hash attributes to Dell SCP format (array of Name/Value/Set On Import objects)
        scp_attributes = case attributes
        when Hash
          attributes.map do |name, value|
            {
              "Name" => name.to_s,
              "Value" => value.to_s,
              "Set On Import" => "True"
            }
          end
        when Array
          attributes # Already in correct format
        else
          []
        end
        
        acc << { "FQDD" => fqdd, "Attributes" => scp_attributes }
        acc
      end
    end

    # Merge multiple SCP configurations together
    # Takes multiple arguments - each can be an SCP hash, array of components, or full SCP structure
    def merge_scp(*scps)
      merged_components = {}
      
      # Get iDRAC version for version-specific handling
      version = begin
        license_version.to_i
      rescue
        9 # Default to iDRAC 9 behavior if version detection fails
      end
      
      scps.compact.each do |scp|
        components = extract_components(scp)
        components.each do |component|
          fqdd = component["FQDD"]
          if merged_components[fqdd]
            # Merge attributes for the same FQDD
            existing_attrs = merged_components[fqdd]["Attributes"] || []
            new_attrs = component["Attributes"] || []
            
            # Build hash of existing attributes by name for easy lookup
            attr_hash = {}
            
            # Handle different attribute structures between iDRAC versions
            existing_attrs.each do |attr|
              case attr
              when Hash
                # iDRAC 8 style: {"Name" => "Users.3#IpmiLanPrivilege", "Value" => "Administrator"}
                attr_hash[attr["Name"]] = attr if attr["Name"]
              when String
                # iDRAC 9 style: strings or different structure - preserve as-is
                # For strings, use the string itself as both key and value
                attr_hash[attr] = attr
              else
                # Unknown structure, preserve as-is with a generated key
                attr_hash["attr_#{attr_hash.size}"] = attr
              end
            end
            
            # Add/overwrite with new attributes
            new_attrs.each do |attr|
              case attr
              when Hash
                attr_hash[attr["Name"]] = attr if attr["Name"]
              when String
                attr_hash[attr] = attr
              else
                attr_hash["attr_#{attr_hash.size}"] = attr
              end
            end
            
            merged_components[fqdd]["Attributes"] = attr_hash.values
          else
            merged_components[fqdd] = component.dup
          end
        end
      end
      
      merged_components.values
    end

    # Handle location header for IP change operations. Monitors old IP until it fails,
    # then monitors job completion at new IP with proper task polling.
    def handle_location_with_ip_change(location, new_ip, timeout: 300)
      return nil if location.nil? || location.empty?
      
      # Extract job ID from location header
      job_id = location.split("/").last
      debug "Extracted job ID: #{job_id}", 1, :cyan
      
      old_ip = @host
      start_time = Time.now
      old_ip_failed = false
      task = nil
      tries = 0
      
      debug "Monitoring IP change with job tracking: #{old_ip} → #{new_ip}", 1, :blue
      
      while Time.now - start_time < timeout
        # Try old IP until it fails, then focus on new IP with job monitoring
        [
          old_ip_failed ? nil : [self, old_ip, "Old IP failed"],
          [create_temp_client(new_ip), new_ip, old_ip_failed ? "New IP not ready" : "Cannot reach new IP"]
        ].compact.each do |client, ip, error_prefix|
          
          begin
            client.login if ip == new_ip
            
            # Test basic connectivity first
            client.authenticated_request(:get, "/redfish/v1", timeout: 2, open_timeout: 1)
            
            if ip == new_ip
              # Once we can reach the new IP, check the job status
              debug "✅ New IP reachable, checking job status...", 1, :green
              begin
                task_response = client.authenticated_request(:get, "/redfish/v1/TaskService/Tasks/#{job_id}", timeout: 10)
                task = JSON.parse(task_response.body)
                
                debug "Job status: #{task['TaskState']} / #{task['TaskStatus']}", 1, :cyan
                
                if task["TaskState"] == "Completed"
                  if task["TaskStatus"] == "OK"
                    debug "✅ Job completed successfully!", 1, :green
                    @host = new_ip
                    return { status: :success, ip: new_ip, job_status: task }
                  else
                    # Job completed but with error
                    msg = task['Messages']&.first&.dig('Message') rescue "N/A"
                    attr = task['Messages']&.first&.dig('Oem', 'Dell', 'Name') rescue "N/A"
                    error_msg = "Job failed: #{msg} : #{attr}, TaskState: #{task['TaskState']}, TaskStatus: #{task['TaskStatus']}"
                    debug "❌ #{error_msg}", 1, :red
                    return { status: :error, error: error_msg, job_status: task }
                  end
                elsif task["TaskState"] == "Running"
                  debug "⏳ Job still running, continuing to wait...", 2, :yellow
                  # Continue monitoring
                else
                  debug "⚠️  Unexpected job state: #{task['TaskState']}", 1, :yellow
                  # Continue monitoring
                end
              rescue => job_error
                debug "Failed to check job status: #{job_error.message}", 2, :yellow
                # Continue monitoring - job might not be ready yet
              end
            else
              # Still on old IP, just test connectivity
              return { status: :success, ip: old_ip }
            end
          rescue => e
            debug "#{error_prefix}: #{e.message}", ip == new_ip ? 2 : 1, ip == new_ip ? :gray : :yellow
            old_ip_failed = true if ip == old_ip
          end
        end
        
        tries += 1
        if tries > 20
          return { status: :timeout, error: "Job monitoring exceeded maximum retries (#{tries})" }
        end
        
        sleep old_ip_failed ? 6 : 5  # Wait longer during IP change
      end
      
      { status: :timeout, error: "IP change timed out after #{timeout}s. Old IP failed: #{old_ip_failed}" }
    end
    
    private
    
    # Wait for job availability, retrying if busy
    def wait_for_job_availability
      loop do
        res = yield
        return res if res.headers["location"].present?
        
        msg = res['error']['@Message.ExtendedInfo'].first['Message']
        details = res['error']['@Message.ExtendedInfo'].first['Resolution']
        
        if details =~ /Wait until the running job is completed/
          sleep 10
        else
          Rails.logger.warn "#{msg}#{details}" if defined?(Rails)
          raise "Failed configuring static IP: #{msg}, #{details}"
        end
      end
    end
    
    # Create temporary client for new IP monitoring  
    def create_temp_client(new_ip)
      self.class.new(
        host: new_ip, username: @username, password: @password,
        port: @port, use_ssl: @use_ssl, verify_ssl: @verify_ssl,
        retry_count: 1, retry_delay: 1
      ).tap { |c| c.verbosity = [@verbosity - 1, 0].max }
    end

    private
    
    # Extract components array from various SCP formats
    def extract_components(scp)
      case scp
      when Hash
        if scp["SystemConfiguration"] && scp["SystemConfiguration"]["Components"]
          scp["SystemConfiguration"]["Components"]
        elsif scp["Components"]
          scp["Components"]  
        elsif scp["FQDD"]
          [scp] # Single component
        else
          # Assume it's a hash of FQDD => attributes
          hash_to_scp(scp)
        end
      when Array
        scp # Already an array of components
      else
        []
      end
    end
  end
end 
