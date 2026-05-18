module IDRAC
  module License
    # Gets the license information from the iDRAC
    # @return [Hash, nil] License details
    def license_info
      # Try standard endpoint first (iDRAC 9+)
      if (data = safe_get("/redfish/v1/LicenseService/Licenses"))
        if data["Members"]&.any?
          license_uri = data["Members"][0]["@odata.id"]
          return safe_get(license_uri) || try_dell_oem_license_path
        end
      end

      try_dell_oem_license_path
    end

    # Extracts the iDRAC generation (e.g. 8, 9) from license or server header
    # @return [Integer, nil]
    def license_version
      @license_version ||= compute_license_version
    end

    def clear_license_version_cache
      @license_version = nil
    end

    private

    def compute_license_version
      license = license_info
      if license
        %w[Description Name LicenseDescription].each do |field|
          if license[field]&.match(/iDRAC(\d+)/i)
            return $1.to_i
          end
        end
      end

      # Fall back to server header
      response = authenticated_request(:get, "/redfish/v1") { |r| r }
      if response.headers["server"]&.match(/iDRAC\/(\d+)/i)
        return $1.to_i
      end

      nil
    end

    def try_dell_oem_license_path
      # Try Dell OEM license service (iDRAC 8)
      if (data = safe_get("/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLicenseManagementService/Licenses"))
        if data["Members"]&.any?
          license_uri = data["Members"][0]["@odata.id"]
          if (details = safe_get(license_uri))
            return {
              "Id" => details["EntitlementID"] || "iDRAC-License",
              "Description" => details["LicenseDescription"] || "iDRAC License",
              "Name" => details["LicenseDescription"] || "iDRAC License",
              "LicenseType" => details["LicenseType"] || license_type_from(details["LicenseDescription"]),
              "Status" => { "Health" => "OK" },
              "Removable" => true
            }
          end
        end
      end

      # Try manager attributes
      if (data = safe_get("/redfish/v1/Managers/iDRAC.Embedded.1/Attributes"))
        attr = data.dig("Attributes", "LicensableDevice.1.LicenseInfo.1") ||
               data.dig("Attributes", "iDRAC.Info.1.LicensingInfo")
        return build_license_hash(license_type_from(attr)) if attr
      end

      # Try manager entity OEM data
      if (data = safe_get("/redfish/v1/Managers/iDRAC.Embedded.1"))
        if (service_uri = data.dig("Oem", "Dell", "DellLicenseManagementService", "@odata.id"))
          if (svc_data = safe_get(service_uri)) && svc_data["Members"]&.any?
            if (details = safe_get(svc_data["Members"][0]["@odata.id"]))
              return {
                "Id" => details["EntitlementID"] || "iDRAC-License",
                "Description" => details["LicenseDescription"] || "iDRAC License",
                "Name" => details["LicenseDescription"] || "iDRAC License",
                "LicenseType" => details["LicenseType"] || license_type_from(details["LicenseDescription"]),
                "Status" => { "Health" => "OK" },
                "Removable" => true
              }
            end
          end
        end

        dell_data = data.dig("Oem", "Dell") || {}
        if dell_data["LicenseType"] || dell_data["License"]
          return build_license_hash(license_type_from(dell_data["LicenseType"] || dell_data["License"]))
        end
      end

      # Last resort: detect from features
      build_license_hash(detect_license_type)
    end

    def license_type_from(str)
      return "Unknown" unless str
      return "Enterprise" if str.include?("Enterprise")
      return "Datacenter" if str.include?("Datacenter")
      return "Express" if str.include?("Express")
      "Basic"
    end

    def build_license_hash(type)
      {
        "Id" => "iDRAC-License",
        "Description" => "iDRAC #{type} License",
        "Name" => "iDRAC License",
        "LicenseType" => type,
        "Status" => { "Health" => "OK" },
        "Removable" => false
      }
    end

    def detect_license_type
      # Virtual media is typically Enterprise-only
      data = safe_get("/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia")
      data ? "Enterprise" : "Express"
    end
  end
end
