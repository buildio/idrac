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
    # Get boot configuration with snake_case fields
    def boot_config
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          boot_data = data["Boot"] || {}
          
          # Get boot options for resolving references
          options_map = {}
          begin
            options = boot_options
            options.each do |opt|
              options_map[opt["id"]] = opt["display_name"] || opt["name"]
            end
          rescue
            # Ignore errors fetching boot options
          end
          
          # Build boot order with resolved names
          boot_order = (boot_data["BootOrder"] || []).map do |ref|
            {
              "reference" => ref,
              "name" => options_map[ref] || ref
            }
          end
          
          # Return hash with snake_case fields
          {
            # Boot override settings (for one-time or continuous boot)
            "boot_source_override_enabled" => boot_data["BootSourceOverrideEnabled"],     # Disabled/Once/Continuous
            "boot_source_override_target" => boot_data["BootSourceOverrideTarget"],       # None/Pxe/Hdd/Cd/etc
            "boot_source_override_mode" => boot_data["BootSourceOverrideMode"],           # UEFI/Legacy
            "allowed_override_targets" => boot_data["BootSourceOverrideTarget@Redfish.AllowableValues"] || [],
            
            # Permanent boot order with resolved names
            "boot_order" => boot_order,                                                    # [{reference: "Boot0001", name: "Ubuntu"}]
            "boot_order_refs" => boot_data["BootOrder"] || [],                            # Raw references for set_boot_order
            
            # UEFI specific fields
            "uefi_target_boot_source_override" => boot_data["UefiTargetBootSourceOverride"],
            "stop_boot_on_fault" => boot_data["StopBootOnFault"],
            
            # References to other resources
            "boot_options_uri" => boot_data.dig("BootOptions", "@odata.id"),
            "certificates_uri" => boot_data.dig("Certificates", "@odata.id")
          }.compact
        rescue JSON::ParserError
          raise Error, "Failed to parse boot response: #{response.body}"
        end
      else
        raise Error, "Failed to get boot configuration. Status code: #{response.status}"
      end
    end
    
    # Get raw Redfish boot data (CamelCase)
    def boot_raw
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if response.status == 200
        data = JSON.parse(response.body)
        data["Boot"] || {}
      else
        raise Error, "Failed to get boot configuration. Status code: #{response.status}"
      end
    end
    
    # Shorter alias for convenience
    def boot
      boot_config
    end
    
    # Get boot options collection - the actual boot devices present in the system
    # This is different from boot_config which returns the boot configuration settings
    def boot_options
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootOptions?$expand=*($levels=1)")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Return the BootOption objects with snake_case
          data["Members"]&.map do |member|
            {
              "id" => member["Id"],                                           # Boot0001
              "boot_option_reference" => member["BootOptionReference"],       # Boot0001  
              "display_name" => member["DisplayName"],                        # "Integrated RAID Controller 1: Ubuntu"
              "name" => member["DisplayName"] || member["Name"],              # Alias for display_name
              "enabled" => member["BootOptionEnabled"],                       # true/false
              "uefi_device_path" => member["UefiDevicePath"],                 # UEFI device path
              "description" => member["Description"]
            }.compact
          end || []
        rescue JSON::ParserError
          raise Error, "Failed to parse boot options response: #{response.body}"
        end
      else
        []
      end
    end
    
    # Legacy method names for backward compatibility
    def get_bios_boot_options
      get_bios_boot_sources
    end
    
    def get_boot_devices
      boot_options
    end
    
    # Set boot override for next boot
    def set_boot_override(target, persistence: nil, mode: nil)
      persistence = "Once" unless persistence
      # Validate target against allowed values
      boot_data = boot
      valid_targets = boot_data["allowed_override_targets"]
      
      if valid_targets && !valid_targets.include?(target)
        debug "Invalid boot target '#{target}'. Allowed values: #{valid_targets.join(', ')}", 1, :red
        raise Error, "Invalid boot target: #{target}"
      end
      
      debug "Setting boot override to #{target} (#{persistence})...", 1, :yellow
      
      body = {
        "Boot" => {
          "BootSourceOverrideEnabled" => persistence,  # Disabled/Once/Continuous
          "BootSourceOverrideTarget" => target     # None/Pxe/Hdd/Cd/etc
        }
      }
      
      # Add boot mode if specified
      body["Boot"]["BootSourceOverrideMode"] = mode if mode
      
      response = authenticated_request(
        :patch,
        "/redfish/v1/Systems/System.Embedded.1",
        body: body.to_json
      )
      
      if response.status.between?(200, 299)
        debug "Boot override set successfully.", 1, :green
        return true
      else
        raise Error, "Failed to set boot override: #{response.status} - #{response.body}"
      end
    end
    
    # Clear boot override settings
    def clear_boot_override
      debug "Clearing boot override...", 1, :yellow
      
      body = {
        "Boot" => {
          "BootSourceOverrideEnabled" => "Disabled"
        }
      }
      
      response = authenticated_request(
        :patch,
        "/redfish/v1/Systems/System.Embedded.1",
        body: body.to_json
      )
      
      if response.status.between?(200, 299)
        debug "Boot override cleared successfully.", 1, :green
        return true
      else
        raise Error, "Failed to clear boot override: #{response.status} - #{response.body}"
      end
    end
    
    # Set the permanent boot order
    def set_boot_order(devices)
      debug "Setting boot order...", 1, :yellow
      
      body = {
        "Boot" => {
          "BootOrder" => devices
        }
      }
      
      response = authenticated_request(
        :patch,
        "/redfish/v1/Systems/System.Embedded.1",
        body: body.to_json
      )
      
      if response.status.between?(200, 299)
        debug "Boot order set successfully.", 1, :green
        return true
      else
        raise Error, "Failed to set boot order: #{response.status} - #{response.body}"
      end
    end
    
    # Convenience methods for common boot targets
    def boot_to_pxe(persistence: nil, mode: nil)
      set_boot_override("Pxe", persistence: persistence, mode: mode)
    end
    
    def boot_to_disk(persistence: nil, mode: nil)
      set_boot_override("Hdd", persistence: persistence, mode: mode)
    end
    
    def boot_to_cd(persistence: nil, mode: nil)
      set_boot_override("Cd", persistence: persistence, mode: mode)
    end
    
    def boot_to_usb(persistence: nil, mode: nil)
      set_boot_override("Usb", persistence: persistence, mode: mode)
    end
    
    def boot_to_bios_setup(persistence: nil, mode: nil)
      set_boot_override("BiosSetup", persistence: persistence, mode: mode)
    end
    
    private
    
    def get_bios_boot_sources
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
    
    public
    
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
              body: payload.to_json
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
            body: { "Boot": { "BootOrder": [boot_id] } }.to_json
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
        body: { "Attributes": settings }.to_json
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
            current_value = data["Attributes"]["ErrPrompt"]
            debug "ErrPrompt current value: '#{current_value}' (checking if == 'Disabled')", 1, :cyan
            return current_value == "Disabled"
          else
            debug "ErrPrompt attribute not found in BIOS settings", 1, :yellow
            debug "Available BIOS attributes: #{data['Attributes']&.keys&.sort&.join(', ')}", 2, :yellow if data["Attributes"]
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
          "Name" => key.to_s,
          "Value" => value,
          "Set On Import" => "True"
        }
      end
      
      scp = {
        "SystemConfiguration" => {
          "Components" => [
            {
              "FQDD" => "BIOS.Setup.1-1",
              "Attributes" => attributes
            }
          ]
        }
      }
      
      return scp
    end
    
    # Import System Configuration Profile for advanced configurations
    def import_system_configuration(scp, target: "ALL", reboot: false)
      params = {
        "ImportBuffer" => JSON.generate(scp),
        "ShareParameters" => {
          "Target" => target
        }
      }
      # Configure shutdown behavior
      params["ShutdownType"] = "Forced"
      params["HostPowerState"] = reboot ? "On" : "Off"
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration",
        body: params.to_json
      )
      
      # Same operation as set_system_configuration_profile: wait on the import JOB.
      return wait_for_scp_import(response.headers["location"])
    end

    ########################################################
    # Boot mechanics moved out of the app's raw Redfish (radfish #40). These used to live in the
    # app's Infra::OsInstall as hand-rolled authenticated_request calls; the iDRAC BootSources /
    # one-time-boot mechanics belong here, the adapter and the radfish facade just expose them.
    ########################################################

    # Stale UEFI boot placeholders a prior OS can leave behind. Dell names them
    # "Unknown.Unknown.<n>-<n>"; left ENABLED they make UEFI loop over dead entries and can keep a
    # node from ever reaching an install (this trapped n008: PXE plus five "Unknown.Unknown" ghosts,
    # no disk entry). The default match targets exactly them.
    STALE_UEFI_BOOT_ENTRY = /\AUnknown\.Unknown\./

    # The still-ENABLED UEFI boot entries whose Name matches +match+ (default: the stale
    # "Unknown.Unknown.*" placeholders). Returns the raw BootSources entry hashes so callers can read
    # Name/Id/Index; [] when there are none. Read-only.
    def stale_uefi_boot_entries(match: STALE_UEFI_BOOT_ENTRY)
      res = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootSources")
      body = res.body.is_a?(String) ? JSON.parse(res.body) : res.body
      seq = body.dig("Attributes", "UefiBootSeq") || []
      seq.select { |e| e["Name"].to_s.match?(match) && e["Enabled"] != false }
    end

    # Disable the UEFI boot entries whose Name matches +match+ (default: the stale
    # "Unknown.Unknown.*" placeholders) and return the NAMES disabled ([] when there was nothing to
    # do). Drains any pending Lifecycle Controller config job FIRST so scheduling ours never trips
    # LC068, then PATCHes BootSources/Settings and POSTs the BIOS config job that applies the change.
    # The disable is applied by a reboot -- the LifecycleController runs the pending job during POST
    # -- so by default this only SCHEDULES it and the caller owns power. Pass wait: true to poll the
    # scheduled BIOS config job to a terminal state here (via wait_config_job) before returning.
    def disable_boot_entries(match: STALE_UEFI_BOOT_ENTRY, wait: false, timeout: 900)
      res = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1/BootSources")
      body = res.body.is_a?(String) ? JSON.parse(res.body) : res.body
      seq = body.dig("Attributes", "UefiBootSeq") || []
      stale = seq.select { |e| e["Name"].to_s.match?(match) && e["Enabled"] != false }
      return [] if stale.empty?

      # A stale pending job would make the config-job POST below hard-fail with LC068; drain first.
      drain_pending_config_jobs!

      newseq = seq.each_with_index.map do |e, i|
        off = e["Name"].to_s.match?(match)
        { "Enabled" => (off ? false : e["Enabled"]), "Id" => e["Id"], "Index" => i, "Name" => e["Name"] }
      end
      patch = authenticated_request(:patch, "/redfish/v1/Systems/System.Embedded.1/BootSources/Settings",
                                    body: JSON.generate("Attributes" => { "UefiBootSeq" => newseq }))
      raise Error, "Disabling stale boot sources failed (HTTP #{patch.status}): #{patch.body}" unless patch.status.between?(200, 299)

      job = authenticated_request(:post, "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs",
                                  body: JSON.generate("TargetSettingsURI" => "/redfish/v1/Systems/System.Embedded.1/BootSources/Settings"))
      raise Error, "BIOS config job for boot sources failed (HTTP #{job.status}): #{job.body}" unless job.status.between?(200, 299)

      # Default: the caller's reboot applies the change (LC runs the pending job during POST). With
      # wait: true, poll the scheduled config job to a terminal state -- reuse Jobs#wait_config_job.
      if wait
        headers = job.respond_to?(:headers) ? (job.headers || {}) : {}
        jid = (headers["location"] || headers["Location"]).to_s[/(JID_\w+)/, 1] || job.body.to_s[/(JID_\w+)/, 1]
        wait_config_job(jid, timeout: timeout) if jid
      end

      names = stale.map { |e| e["Name"] }
      puts "Disabled #{names.size} stale UEFI boot #{names.size == 1 ? 'entry' : 'entries'} " \
           "(#{names.join(', ')}); a BIOS config job applies it at the next boot.".green
      names
    end

    # Redfish BootProgress.LastState mapped to the snake_case symbols radfish orders boots by
    # (Radfish::Client::BOOT_PROGRESS_ORDER). Explicit so the acronym cases (PCI, OS) normalize
    # correctly instead of through a naive underscore.
    BOOT_PROGRESS_STATES = {
      "None" => :none,
      "PrimaryProcessorInitializationStarted" => :primary_processor_initialization_started,
      "BusInitializationStarted" => :bus_initialization_started,
      "MemoryInitializationStarted" => :memory_initialization_started,
      "SecondaryProcessorInitializationStarted" => :secondary_processor_initialization_started,
      "PCIResourceConfigStarted" => :pci_resource_config_started,
      "SystemHardwareInitializationComplete" => :system_hardware_initialization_complete,
      "SetupEntered" => :setup_entered,
      "OSBootStarted" => :os_boot_started,
      "OSRunning" => :os_running
    }.freeze

    # Normalized last BootProgress state (a snake_case Symbol from BOOT_PROGRESS_STATES), or nil when
    # the BMC does not report BootProgress at all (iDRAC8 omits it). nil means "cannot observe", never
    # "not running" -- callers fall back to other signals.
    def boot_progress
      res = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1?$select=BootProgress")
      body = res.body.is_a?(String) ? JSON.parse(res.body) : res.body
      last = body.is_a?(Hash) ? body.dig("BootProgress", "LastState") : nil
      return nil if last.nil? || last.to_s.empty?
      BOOT_PROGRESS_STATES[last] || last.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
    end

    # Dell one-time boot to the virtual CD via an SCP import (the reliable path on this fleet). Drains
    # any pending Lifecycle Controller config job first (a stale one makes the import hard-fail with
    # LC068 "a configuration job is already scheduled"), then imports ServerBoot.1#BootOnce +
    # FirstBootDevice=VCD-DVD. BootOnce makes the BIOS fall back to the standing order after one boot,
    # so no boot-order reorder is needed here. Raises on a failed import; returns the import result hash.
    def set_one_time_cd_boot(reboot: false)
      drain_pending_config_jobs!
      scp = { "FQDD" => "iDRAC.Embedded.1", "Attributes" => [
        { "Name" => "ServerBoot.1#BootOnce", "Value" => "Enabled", "Set On Import" => "True" },
        { "Name" => "ServerBoot.1#FirstBootDevice", "Value" => "VCD-DVD", "Set On Import" => "True" } ] }
      res = set_system_configuration_profile(scp, target: "ALL", reboot: reboot)
      unless res.is_a?(Hash) && res[:status] == :success
        raise Error, "SCP one-time vCD boot failed: #{res[:job_state]} #{res[:error] || res[:message]} (job #{res[:job_id]})"
      end
      res
    end
  end
end
