require 'json'
require 'colorize'

########################################################
# BIOS Configuration / Boot Order
########################################################
# BEWARE YE WHO ENTER HERE
# This is the BIOS configuration and boot order section.
# It is a dark and dangerous place, fraught with peril.
#
# BIOS and UEFI and iDRAC all interplay through a handful of REST API calls and
# a labyrinth of system configuration profile settings. You must know if you are
# in UEFI or BIOS mode to even know which calls to make and some calls "unlock"
# only AFTER you make a switch between modes. Which requires an explicit reboot.
#
# Two current open issues remain:
#  - How do you avoid booting from an installed USB with a bootable image? (workaround--wipefs the USB)
#  - How do you boot-once to the Virtual CD, install Ubuntu, on its natural reboot step, boot to the HD. (workaround--finish install with poweroff)
#
# Get oriented:
# https://github.com/dell/dellemc-openmanage-ansible-modules/issues/21
# https://www.dell.com/support/manuals/en-us/openmanage-ansible-modules/user_guide_1_0_1/configuring-bios?guid=guid-d2d8d871-c3e1-48d1-a879-197670fe33ea&lang=en-us
# https://www.dell.com/support/manuals/en-us/idrac7-8-lifecycle-controller-v2.40.40.40/redfish%202.40.40.40/computersystem?guid=guid-071f0516-1b31-4a4b-90ab-4f9bfcc5db4a&lang=en-us
# https://infohub.delltechnologies.com/en-US/l/server-configuration-profiles-reference-guide/changing-the-boot-order-2/
# https://pubs.lenovo.com/xcc-restapi/update_next_onetime_bootconfig_patch
# https://github.com/dell/iDRAC-Redfish-Scripting/issues/186
# https://www.dell.com/support/kbdoc/en-us/000198504/boot-device-fqdd-name-changed-in-15g-bios-uefi-boot-sequence-after-bios-update
# https://github.com/dell/iDRAC-Redfish-Scripting/issues/116
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
            
            wait_for_job(response.headers["location"])
          end
        rescue JSON::ParserError
          raise Error, "Failed to parse BIOS response: #{response.body}"
        end
      else
        raise Error, "Failed to get BIOS information. Status code: #{response.status}"
      end
    end
=begin
    # Servers can boot in BIOS mode or in UEFI (modern, extensible BIOS replacement) mode.
    # We use UEFI mode.
    # self.get(path: "Systems/System.Embedded.1/Bios/Settings?$select=BootMode")
    res = self.get(path: "Systems/System.Embedded.1/Bios")
    if res["body"]["Attributes"]["BootMode"] == "Uefi"
      return { status: :success }
    else
      res = self.set_system_configuration_profile(scp_boot_mode_uefi, reboot: true)
      # Then must power cycle the server
      self.power_on!(wait: true)
      self.power_off!(wait: true)
      return res
    end

=end
    def scp_boot_mode_uefi(idrac_license_version: 9)
      opts = { "BootMode" => 'Uefi' }
      # If we're iDRAC 9, we need enable a placeholder, otherwise we can't order the
      # boot order until we've switched to UEFI mode.
      # Read [about it](https://dl.dell.com/manuals/all-products/esuprt_software/esuprt_it_ops_datcentr_mgmt/dell-management-solution-resources_white-papers12_en-us.pdf).
      # ...administrators may wish to reserve a boot entry for a fixed disk in the UEFI Boot Sequence before an OS is installed or before a physical or
      # virtual drive has been formatted. When a HardDisk Drive Placeholder is set to Enabled, the BIOS will create a boot option for the PERC RAID
      # (Integrated or in a PCIe slot) disk if a partition is found, even if there is no FAT filesystem present... this allows the Integrated RAID controller
      # to be moved in the UEFI Boot Sequence prior to the OS installation
      opts["HddPlaceholder"] = "Enabled" if idrac_license_version.to_i == 9
      self.make_scp(fqdd: "BIOS.Setup.1-1", attributes: opts)
    end
    # What triggers a reboot?
    # https://infohub.delltechnologies.com/en-US/l/server-configuration-profiles-reference-guide/host-reboot-2/
    def set_bios(hash)
      scp = self.make_scp(fqdd: "BIOS.Setup.1-1", attributes: hash)
      res = self.set_system_configuration_profile(scp)
      if res[:status] == :success
        self.get_bios_boot_options
      end
      res
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

    def set_uefi_boot_cd_once_then_hd
      boot_options = get_bios_boot_options[:boot_options]
      # Note may have to put device into
      # self.set_bios( { "BootMode" => 'Uefi' } )
      # self.reboot!
      # And then reboot before you can make the following call:
      raid_name = boot_options.include?("RAID.Integrated.1-1") ? "RAID.Integrated.1-1" : "Unknown.Unknown.1-1"
      raise "No RAID HD in boot options" unless boot_options.include?(raid_name)
      bios = {
          "BootMode" => 'Uefi',
          "BootSeqRetry" => "Disabled",

          # "UefiTargetBootSourceOverride" => 'Cd',
          # "BootSourceOverrideTarget" => 'UefiTarget',
          # "OneTimeBootMode"       => "OneTimeUefiBootSeq",

          # One time boot order
          # "OneTimeHddSeqDev"      => "Optical.iDRACVirtual.1-1",
          # "OneTimeBiosBootSeqDev" => "Optical.iDRACVirtual.1-1",
          # "OneTimeUefiBootSeqDev" => "Optical.iDRACVirtual.1-1",

          # Enabled/Disabled Options
          # "SetBootOrderDis" => "Disk.USBBack.1-1",  # Don't boot to USB if it is plugged in
          "SetBootOrderEn"    => raid_name,
          # "SetBootOrderFqdd1" => raid_name,
          # "SetLegacyHddOrderFqdd1" => raid_name,
          # "SetBootOrderFqdd2" => "Optical.iDRACVirtual.1-1",

          # Permanent Boot Order
          "HddSeq"      => raid_name,
          "BiosBootSeq" => raid_name,
          "UefiBootSeq" => raid_name # This is likely redundant...
        }
      # The usb device will have 'usb' in it:
      usb_name = boot_options.select { |b| b =~ /usb/i }
      bios["SetBootOrderDis"] = usb_name if usb_name.present?

      set_bios(bios)
    end

    # This sets boot to HD but before that it sets the one-time boot to CD
    # Different approach for iDRAC 8 vs 9
    def override_boot_source
      # For now try with all iDRAC versions
      if self.license_version.to_i == 9
        set_boot_order_hd_first()
        set_one_time_virtual_media_boot()
      else
        scp = {"FQDD"=>"iDRAC.Embedded.1", "Attributes"=> [{"Name"=>"ServerBoot.1#BootOnce", "Value"=>"Enabled", "Set On Import"=>"True"}, {"Name"=>"ServerBoot.1#FirstBootDevice", "Value"=>"VCD-DVD", "Set On Import"=>"True"}]}
        # set_uefi_boot_cd_once_then_hd
        # scp = self.set_bios_boot_cd_first
        # get_bios_boot_options # Make sure we know if the OS is calling it Unknown or RAID
        # {"FQDD"=>"BIOS.Setup.1-1", "Attributes"=>
        # [{"Name"=>"ServerBoot.1#BootOnce",       "Value"=>"Enabled", "Set On Import"=>"True"},
        # {"Name"=>"ServerBoot.1#FirstBootDevice", "Value"=>"VCD-DVD", "Set On Import"=>"True"},
        # {"Name"=>"BootSeqRetry",                 "Value"=>"Disabled", "Set On Import"=>"True"},
        # {"Name"=>"UefiBootSeq",                  "Value"=>"Unknown.Unknown.1-1,NIC.PxeDevice.1-1,Floppy.iDRACVirtual.1-1,Optical.iDRACVirtual.1-1",
        #  "Set On Import"=>"True"}]}

        # 3.3.0 :018 > scp1 = {"FQDD"=>"BIOS.Setup.1-1", "Attributes"=> [{"Name"=>"OneTimeUefiBootSeq", "Value"=>"VCD-DVD", "Set On Import"=>"True"}, {"Name"=>"BootSeqRetry", "Value"=>"Disabled", "Set On Import"=>"True"}, {"Name"=>"UefiBootSeq", "Value"=>"Unknown.Unknown.1-1,NIC.PxeDevice.1-1", "Set On Import"=>"True"}]}
        set_system_configuration_profile(scp) # This will cycle power and leave the device off.
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
    
    # Check if BIOS error prompt is disabled
    def bios_error_prompt_disabled?
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/Bios")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          if data["Attributes"] && data["Attributes"].has_key?("ErrPrompt")
            return data["Attributes"]["ErrPrompt"] == "Disabled"
          else
            debug "ErrPrompt attribute not found in BIOS settings", 1, :yellow
            return false
          end
        rescue JSON::ParserError
          debug "Failed to parse BIOS response", 0, :red
          return false
        end
      else
        debug "Failed to get BIOS information. Status code: #{response.status}", 0, :red
        return false
      end
    end

    def bios_hdd_placeholder_enabled?
      case self.license_version.to_i
      when 8
        # scp = usable_scp(get_system_configuration_profile(target: "BIOS"))
        # scp["BIOS.Setup.1-1"]["HddPlaceholder"] == "Enabled"
        true
      else
        response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/Bios")
        json = JSON.parse(response.body)
        raise "Error reading HddPlaceholder setup" if json&.dig('Attributes','HddPlaceholder').blank?
        json["Attributes"]["HddPlaceholder"] == "Enabled"
      end
    end

    def bios_os_power_control_enabled?
      case self.license_version.to_i
      when 8
        scp = usable_scp(get_system_configuration_profile(target: "BIOS"))
        scp["BIOS.Setup.1-1"]["ProcCStates"] == "Enabled" &&
          scp["BIOS.Setup.1-1"]["SysProfile"] == "PerfPerWattOptimizedOs" &&
          scp["BIOS.Setup.1-1"]["ProcPwrPerf"] == "OsDbpm"
      else
        response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/Bios")
        json = JSON.parse(response.body)
        raise "Error reading PowerControl setup" if json&.dig('Attributes').blank?
        json["Attributes"]["ProcCStates"] == "Enabled" &&
          json["Attributes"]["SysProfile"] == "PerfPerWattOptimizedOs" &&
          json["Attributes"]["ProcPwrPerf"] == "OsDbpm"
      end
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
      
      task = wait_for_task(response.headers["location"])
      debugger
      return task
    end
  end
end 
