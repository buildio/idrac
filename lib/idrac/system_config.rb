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
          body: {"ImportBuffer": scp.to_json, "ShareParameters": {"Target": "iDRAC"}}.to_json,
          headers: {"Content-Type" => "application/json"}
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
        body: {"ExportFormat": "JSON", "ShareParameters":{"Target": target}}.to_json,
        headers: {"Content-Type" => "application/json"}
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



    # Handle location header for IP change operations. Monitors old IP until it fails,
    # then aggressively monitors new IP with tight timeouts.
    def handle_location_with_ip_change(location, new_ip, timeout: 300)
      return nil if location.nil? || location.empty?
      
      old_ip = @host
      start_time = Time.now
      old_ip_failed = false
      
      debug "Monitoring IP change: #{old_ip} → #{new_ip}", 1, :blue
      
      while Time.now - start_time < timeout
        # Try old IP until it fails, then focus on new IP
        [
          old_ip_failed ? nil : [self, old_ip, "Old IP failed"],
          [create_temp_client(new_ip), new_ip, old_ip_failed ? "New IP not ready" : "Cannot reach new IP"]
        ].compact.each do |client, ip, error_prefix|
          
          begin
            client.login if ip == new_ip
            client.authenticated_request(:get, "/redfish/v1", timeout: 2, open_timeout: 1)
            
            if ip == new_ip
              debug "✅ IP change successful!", 1, :green
              @host = new_ip
              return { status: :success, ip: new_ip }
            else
              return { status: :success, ip: old_ip }
            end
          rescue => e
            debug "#{error_prefix}: #{e.message}", ip == new_ip ? 2 : 1, ip == new_ip ? :gray : :yellow
            old_ip_failed = true if ip == old_ip
          end
        end
        
        sleep old_ip_failed ? 2 : 5
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
  end
end 
