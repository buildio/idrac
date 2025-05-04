module IDRAC
  module License
    # Gets the license information from the iDRAC
    # @return [Hash] License details
    def license_info
      # Try the standard license endpoint first (works in iDRAC 9+)
      response = authenticated_request(:get, "/redfish/v1/LicenseService/Licenses")
      
      if response.status == 200
        license_data = JSON.parse(response.body)
        debug "License collection: #{license_data}", 2

        # Check if there are any license entries
        if !license_data["Members"] || license_data["Members"].empty?
          debug "No licenses found", 1, :yellow
          return try_dell_oem_license_path()
        end

        # Get the first license in the list
        license_uri = license_data["Members"][0]["@odata.id"]
        debug "Using license URI: #{license_uri}", 2

        # Get detailed license information
        license_response = authenticated_request(:get, license_uri)
        if license_response.status != 200
          debug "Failed to retrieve license details: #{license_response.status}", 1, :red
          return try_dell_oem_license_path()
        end

        license_details = JSON.parse(license_response.body)
        debug "License details: #{license_details}", 2

        return license_details
      else
        # The endpoint is not available (probably iDRAC 8)
        debug "Standard license endpoint failed: #{response.status}, trying Dell OEM path", 1, :yellow
        return try_dell_oem_license_path()
      end
    end

    # Extracts the iDRAC version from the license description or server header
    # @return [Integer, nil] The license version (e.g. 9) or nil if not found
    def license_version
      # First try to get from license info
      license = license_info
      if license
        # Check the Description field, which often contains the version
        # Example: "iDRAC9 Enterprise License"
        if license["Description"]&.match(/iDRAC(\d+)/i)
          version = license["Description"].match(/iDRAC(\d+)/i)[1].to_i
          debug "Found license version from Description: #{version}", 1
          return version
        end

        # Try alternative fields if Description didn't work
        if license["Name"]&.match(/iDRAC(\d+)/i)
          version = license["Name"].match(/iDRAC(\d+)/i)[1].to_i
          debug "Found license version from Name: #{version}", 1
          return version
        end
        
        # For Dell OEM license response format
        if license["LicenseDescription"]&.match(/iDRAC(\d+)/i)
          version = license["LicenseDescription"].match(/iDRAC(\d+)/i)[1].to_i
          debug "Found license version from LicenseDescription: #{version}", 1
          return version
        end
      end
      
      # If license info failed or didn't have version info, try to get from server header
      # Make a simple request to check the server header (often contains iDRAC version)
      response = authenticated_request(:get, "/redfish/v1")
      if response.headers["server"] && response.headers["server"].match(/iDRAC\/(\d+)/i)
        version = response.headers["server"].match(/iDRAC\/(\d+)/i)[1].to_i
        debug "Found license version from server header: #{version}", 1
        return version
      end
      
      debug "Could not determine license version from license info or server header", 1, :yellow
      nil
    end
    
    private
    
    # Attempt to get license information using Dell OEM extension path (for iDRAC 8)
    # @return [Hash, nil] License info or nil if not found
    def try_dell_oem_license_path
      # Try several potential Dell license paths (order matters - most likely first)
      dell_license_paths = [
        "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLicenseManagementService/Licenses",
        "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes", # iDRAC attributes might contain license info
        "/redfish/v1/Managers/iDRAC.Embedded.1"             # Manager entity might have license info embedded
      ]
      
      dell_license_paths.each do |path|
        response = authenticated_request(:get, path)
        
        if response.status == 200
          debug "Found valid Dell license path: #{path}", 2
          data = JSON.parse(response.body)
          
          # Check for license info in this response based on the path
          if path.include?("DellLicenseManagementService")
            return handle_dell_license_service_response(data)
          elsif path.include?("Attributes")
            return handle_dell_attributes_response(data)
          elsif path.include?("iDRAC.Embedded.1") && !path.include?("Attributes")
            return handle_dell_manager_response(data)
          end
        else
          debug "Dell path #{path} response status: #{response.status}", 3
        end
      end
      
      # If we couldn't find any API path that works, try the service tag detection method 
      service_tag = get_service_tag
      if service_tag
        # Service tag is often used to indicate Enterprise licenses on Dell systems
        license_type = determine_license_type()
        return {
          "Id" => "iDRAC-License",
          "Description" => "iDRAC8 #{license_type} License",
          "Name" => "iDRAC License",
          "LicenseType" => license_type,
          "Status" => { "Health" => "OK" },
          "Removable" => false,
          "EntitlementID" => service_tag # Dell often uses service tag as entitlement ID
        }
      end
      
      # Fall back to feature detection if all else fails
      debug "All Dell OEM license paths failed, using fallback detection", 1, :yellow
      return create_fallback_license_info()
    end
    
    # Handle response from Dell License Management Service
    def handle_dell_license_service_response(data)
      # Check if there are any license entries
      if !data["Members"] || data["Members"].empty?
        debug "No licenses found in Dell OEM path", 1, :yellow
        return create_fallback_license_info(use_basic: true)
      end
      
      # Get the first license in the list
      license_uri = data["Members"][0]["@odata.id"]
      debug "Using Dell OEM license URI: #{license_uri}", 2
      
      # Get detailed license information
      license_response = authenticated_request(:get, license_uri)
      if license_response.status != 200
        debug "Failed to retrieve Dell OEM license details: #{license_response.status}", 1, :red
        return create_fallback_license_info(use_basic: true)
      end
      
      dell_license = JSON.parse(license_response.body)
      debug "Dell OEM license details: #{dell_license}", 2
      
      # Convert Dell OEM license format to standard format
      license_info = {
        "Id" => dell_license["EntitlementID"] || "iDRAC-License",
        "Description" => dell_license["LicenseDescription"] || "iDRAC License",
        "Name" => dell_license["LicenseDescription"] || "iDRAC License",
        "LicenseType" => dell_license["LicenseType"] || get_license_type_from_description(dell_license["LicenseDescription"]),
        "Status" => { "Health" => "OK" },
        "Removable" => true
      }
      
      return license_info
    end
    
    # Handle response from Dell Manager attributes
    def handle_dell_attributes_response(data)
      # Look for license information in attributes
      if data["Attributes"] && (
          data["Attributes"]["LicensableDevice.1.LicenseInfo.1"] ||
          data["Attributes"]["System.ServerOS.1.OSName"] ||
          data["Attributes"]["iDRAC.Info.1.LicensingInfo"]
        )
        
        license_info = data["Attributes"]["LicensableDevice.1.LicenseInfo.1"] || 
                       data["Attributes"]["iDRAC.Info.1.LicensingInfo"]
        
        if license_info
          license_type = license_info.include?("Enterprise") ? "Enterprise" : 
                         license_info.include?("Express") ? "Express" : "Basic"
          
          return {
            "Id" => "iDRAC-License",
            "Description" => "iDRAC8 #{license_type} License",
            "Name" => "iDRAC License",
            "LicenseType" => license_type,
            "Status" => { "Health" => "OK" },
            "Removable" => false
          }
        end
      end
      
      # If no license attributes found, fall back to feature detection
      license_type = determine_license_type()
      return {
        "Id" => "iDRAC-License",
        "Description" => "iDRAC8 #{license_type} License",
        "Name" => "iDRAC License",
        "LicenseType" => license_type,
        "Status" => { "Health" => "OK" },
        "Removable" => false
      }
    end
    
    # Handle response from Dell Manager entity
    def handle_dell_manager_response(data)
      # Look for license information in Oem data
      if data["Oem"] && data["Oem"]["Dell"]
        dell_data = data["Oem"]["Dell"]
        
        if dell_data["DellLicenseManagementService"]
          # Found license service reference, but need to query it directly
          service_uri = dell_data["DellLicenseManagementService"]["@odata.id"]
          debug "Found license service URI: #{service_uri}", 2
          
          service_response = authenticated_request(:get, service_uri)
          if service_response.status == 200
            return handle_dell_license_service_response(JSON.parse(service_response.body))
          end
        end
        
        # Check if license info is embedded directly
        if dell_data["LicenseType"] || dell_data["License"]
          license_type = dell_data["LicenseType"] || 
                        (dell_data["License"] && dell_data["License"].include?("Enterprise") ? "Enterprise" : 
                         dell_data["License"].include?("Express") ? "Express" : "Basic")
          
          return {
            "Id" => "iDRAC-License",
            "Description" => "iDRAC8 #{license_type} License",
            "Name" => "iDRAC License",
            "LicenseType" => license_type,
            "Status" => { "Health" => "OK" },
            "Removable" => false
          }
        end
      end
      
      # Check for license type in model name or description
      if data["Model"] && data["Model"].include?("Enterprise")
        return {
          "Id" => "iDRAC-License",
          "Description" => "iDRAC8 Enterprise License",
          "Name" => "iDRAC License",
          "LicenseType" => "Enterprise",
          "Status" => { "Health" => "OK" },
          "Removable" => false
        }
      end
      
      # If no license info found in manager data, fall back to feature detection
      license_type = determine_license_type()
      return {
        "Id" => "iDRAC-License",
        "Description" => "iDRAC8 #{license_type} License",
        "Name" => "iDRAC License",
        "LicenseType" => license_type,
        "Status" => { "Health" => "OK" },
        "Removable" => false
      }
    end
    
    # Get service tag from system info
    def get_service_tag
      response = authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      if response.status == 200
        data = JSON.parse(response.body)
        return data["SKU"] if data["SKU"] # Service tag is usually in SKU field
      end
      
      # Try alternate location
      response = authenticated_request(:get, "/redfish/v1")
      if response.status == 200
        data = JSON.parse(response.body)
        if data["Oem"] && data["Oem"]["Dell"] && data["Oem"]["Dell"]["ServiceTag"]
          return data["Oem"]["Dell"]["ServiceTag"]
        end
      end
      
      nil
    end
    
    # Helper method to extract license type from description
    def get_license_type_from_description(description)
      return "Unknown" unless description
      
      if description.include?("Enterprise")
        return "Enterprise"
      elsif description.include?("Express")
        return "Express"
      elsif description.include?("Datacenter")
        return "Datacenter"
      else
        return "Basic"
      end
    end
    
    # Creates a basic license info object based on system information
    # Used as a fallback when neither the standard nor Dell OEM endpoints work
    # @return [Hash] A basic license info object
    def create_fallback_license_info(use_basic: false)
      # Get the iDRAC version number from server headers
      version = nil
      response = authenticated_request(:get, "/redfish/v1")
      if response.headers["server"] && response.headers["server"].match(/iDRAC\/(\d+)/i)
        version = response.headers["server"].match(/iDRAC\/(\d+)/i)[1].to_i
      end
      
      # Try to determine if it's Enterprise or Express based on available features
      license_type = use_basic ? "Basic" : determine_license_type
      
      license_info = {
        "Id" => "iDRAC-License",
        "Description" => version ? "iDRAC#{version} #{license_type} License" : "iDRAC License",
        "Name" => "iDRAC License",
        "LicenseType" => license_type,
        "Status" => { "Health" => "OK" },
        "Removable" => false
      }
      
      debug "Created fallback license info: #{license_info}", 2
      license_info
    end
    
    # Attempt to determine the license type (Enterprise/Express) based on available features
    # @return [String] The license type (Enterprise, Express, or Basic)
    def determine_license_type
      # We can try to check for features only available in Enterprise
      begin
        # For example, virtual media is typically an Enterprise feature
        virtual_media_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia")
        # If we successfully get virtual media, it's likely Enterprise
        if virtual_media_response.status == 200
          return "Enterprise" 
        end
      rescue
        # If the request fails, don't fail the whole method
      end
      
      # Default to basic license if we can't determine
      return "Express"
    end
  end
end 