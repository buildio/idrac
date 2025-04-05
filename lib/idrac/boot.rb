require 'json'
require 'colorize'

module IDRAC
  module Boot
    # Get BIOS boot options
    def get_bios_boot_options
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootSources")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          if data["Attributes"]["UefiBootSeq"].blank?
            puts "Not in UEFI mode".red
            return false
          end
          
          boot_order = []
          boot_options = []
          
          data["Attributes"]["UefiBootSeq"].each do |seq|
            puts "#{seq["Name"]} > #{seq["Enabled"]}".yellow
            boot_options << seq["Name"]
            boot_order << seq["Name"] if seq["Enabled"]
          end
          
          return {
            boot_options: boot_options,
            boot_order: boot_order
          }
        rescue JSON::ParserError
          raise Error, "Failed to parse BIOS boot options response: #{response.body}"
        end
      else
        raise Error, "Failed to get BIOS boot options. Status code: #{response.status}"
      end
    end
    
    # Ensure UEFI boot mode
    def ensure_uefi_boot
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/Bios")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          if data["Attributes"]["BootMode"] == "Uefi"
            puts "System is already in UEFI boot mode".green
            return true
          else
            puts "System is not in UEFI boot mode. Setting to UEFI...".yellow
            
            # Create payload for UEFI boot mode
            payload = {
              "Attributes": {
                "BootMode": "Uefi"
              }
            }
            
            # If iDRAC 9, we need to enable HddPlaceholder
            if get_idrac_version == 9
              payload[:Attributes][:HddPlaceholder] = "Enabled"
            end
            
            response = authenticated_request(
              :patch, 
              "/redfish/v1/Systems/System.Embedded.1/Bios/Settings",
              body: payload.to_json,
              headers: { 'Content-Type': 'application/json' }
            )
            
            if response.status.between?(200, 299)
              puts "UEFI boot mode set. A system reboot is required for changes to take effect.".green
              
              # Check for job creation
              if response.headers["Location"]
                job_id = response.headers["Location"].split("/").last
                wait_for_job(job_id)
              end
              
              return true
            else
              error_message = "Failed to set UEFI boot mode. Status code: #{response.status}"
              
              begin
                error_data = JSON.parse(response.body)
                if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
                  error_info = error_data["error"]["@Message.ExtendedInfo"].first
                  error_message += ", Message: #{error_info['Message']}"
                end
              rescue
                # Ignore JSON parsing errors
              end
              
              raise Error, error_message
            end
          end
        rescue JSON::ParserError
          raise Error, "Failed to parse BIOS response: #{response.body}"
        end
      else
        raise Error, "Failed to get BIOS information. Status code: #{response.status}"
      end
    end
    
    # Set boot order (HD first)
    def set_boot_order_hd_first
      # First ensure we're in UEFI mode
      ensure_uefi_boot
      
      # Get available boot options
      boot_options_response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootOptions?$expand=*($levels=1)")
      
      if boot_options_response.status == 200
        begin
          data = JSON.parse(boot_options_response.body)
          
          puts "Available boot options:"
          data["Members"].each { |m| puts "\t#{m['DisplayName']} -> #{m['Id']}" }
          
          # Find RAID controller or HD
          device = data["Members"].find { |m| m["DisplayName"] =~ /RAID Controller/ }
          # Sometimes it's named differently
          device ||= data["Members"].find { |m| m["DisplayName"] =~ /ubuntu/i }
          device ||= data["Members"].find { |m| m["DisplayName"] =~ /UEFI Hard Drive/i }
          device ||= data["Members"].find { |m| m["DisplayName"] =~ /Hard Drive/i }
          
          if device.nil?
            raise Error, "No bootable hard drive or RAID controller found in boot options"
          end
          
          boot_id = device["Id"]
          
          # Set boot order
          response = authenticated_request(
            :patch, 
            "/redfish/v1/Systems/System.Embedded.1",
            body: { "Boot": { "BootOrder": [boot_id] } }.to_json,
            headers: { 'Content-Type': 'application/json' }
          )
          
          if response.status.between?(200, 299)
            puts "Boot order set to HD first".green
            return true
          else
            error_message = "Failed to set boot order. Status code: #{response.status}"
            
            begin
              error_data = JSON.parse(response.body)
              if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
                error_info = error_data["error"]["@Message.ExtendedInfo"].first
                error_message += ", Message: #{error_info['Message']}"
              end
            rescue
              # Ignore JSON parsing errors
            end
            
            raise Error, error_message
          end
        rescue JSON::ParserError
          raise Error, "Failed to parse boot options response: #{response.body}"
        end
      else
        raise Error, "Failed to get boot options. Status code: #{boot_options_response.status}"
      end
    end
    
    # Configure BIOS settings
    def configure_bios_settings(settings)
      response = authenticated_request(
        :patch, 
        "/redfish/v1/Systems/System.Embedded.1/Bios/Settings",
        body: { "Attributes": settings }.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      if response.status.between?(200, 299)
        puts "BIOS settings configured. A system reboot is required for changes to take effect.".green
        
        # Check if we need to wait for a job
        if response.headers["Location"]
          job_id = response.headers["Location"].split("/").last
          wait_for_job(job_id)
        end
        
        return true
      else
        error_message = "Failed to configure BIOS settings. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
            error_info = error_data["error"]["@Message.ExtendedInfo"].first
            error_message += ", Message: #{error_info['Message']}"
          end
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
    
    # Configure BIOS to optimize for OS power management
    def set_bios_os_power_control
      settings = {
        "ProcCStates": "Enabled",      # Processor C-States
        "SysProfile": "PerfPerWattOptimizedOs",
        "ProcPwrPerf": "OsDbpm",       # OS Power Management
        "PcieAspmL1": "Enabled"        # PCIe Active State Power Management
      }
      
      configure_bios_settings(settings)
    end
    
    # Configure BIOS to ignore boot errors
    def set_bios_ignore_errors(value = true)
      configure_bios_settings({
        "ErrPrompt": value ? "Disabled" : "Enabled"
      })
    end
    
    # Get iDRAC version - needed for boot management differences
    def get_idrac_version
      response = authenticated_request(:get, "/redfish/v1")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          redfish = data["RedfishVersion"]
          server = response.headers["server"]
          
          case server.to_s.downcase
          when /appweb\/4.5.4/, /idrac\/8/
            return 8
          when /apache/, /idrac\/9/
            return 9
          else
            # Try to determine by RedfishVersion as fallback
            if redfish == "1.4.0"
              return 8
            elsif redfish == "1.18.0"
              return 9
            else
              raise Error, "Unknown iDRAC version: #{server} / #{redfish}"
            end
          end
        rescue JSON::ParserError
          raise Error, "Failed to parse iDRAC response: #{response.body}"
        end
      else
        raise Error, "Failed to get iDRAC information. Status code: #{response.status}"
      end
    end
    
    # Create System Configuration Profile for BIOS settings
    def create_scp_for_bios(settings)
      attributes = []
      
      settings.each do |key, value|
        attributes << {
          "Name": key.to_s,
          "Value": value,
          "Set On Import": "True"
        }
      end
      
      scp = {
        "SystemConfiguration": {
          "Components": [
            {
              "FQDD": "BIOS.Setup.1-1",
              "Attributes": attributes
            }
          ]
        }
      }
      
      return scp
    end
    
    # Import System Configuration Profile for advanced configurations
    def import_system_configuration(scp, target: "ALL", reboot: false)
      params = {
        "ImportBuffer": JSON.pretty_generate(scp),
        "ShareParameters": {
          "Target": target
        }
      }
      
      # Configure shutdown behavior
      params["ShutdownType"] = "Forced"
      params["HostPowerState"] = reboot ? "On" : "Off"
      
      response = authenticated_request(
        :post, 
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration",
        body: params.to_json,
        headers: { 'Content-Type': 'application/json' }
      )
      
      if response.status.between?(200, 299)
        # Check if we need to wait for a job
        if response.headers["location"]
          job_id = response.headers["location"].split("/").last
          
          job = wait_for_job(job_id)
          
          # Check for task completion status
          if job["TaskState"] == "Completed" && job["TaskStatus"] == "OK"
            puts "System configuration imported successfully".green
            return true
          else
            # If there's an error message with a line number, surface it
            error_message = "Failed to import system configuration"
            
            if job["Messages"]
              job["Messages"].each do |m|
                puts "#{m["Message"]} (#{m["Severity"]})".red
                
                # Check for line number in error message
                if m["Message"] =~ /line (\d+)/
                  line_num = $1.to_i
                  lines = JSON.pretty_generate(scp).split("\n")
                  puts "Error near line #{line_num}:".red
                  ((line_num-3)..(line_num+1)).each do |ln|
                    puts "#{ln}: #{lines[ln-1]}" if ln > 0 && ln <= lines.length
                  end
                end
              end
            end
            
            raise Error, error_message
          end
        else
          puts "System configuration import started, but no job ID was returned".yellow
          return true
        end
      else
        error_message = "Failed to import system configuration. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
            error_info = error_data["error"]["@Message.ExtendedInfo"].first
            error_message += ", Message: #{error_info['Message']}"
          end
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
  end
end 