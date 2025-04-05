module IDRAC
  module License
    # Gets the license information from the iDRAC
    # @return [RecursiveOpenStruct] License details
    def license_info
      response = authenticated_request(:get, "/redfish/v1/LicenseService/Licenses")
      if response.status != 200
        debug "Failed to retrieve licenses list: #{response.status}", 1, :red
        return nil
      end

      license_data = JSON.parse(response.body)
      debug "License collection: #{license_data}", 2

      # Check if there are any license entries
      if !license_data["Members"] || license_data["Members"].empty?
        debug "No licenses found", 1, :yellow
        return nil
      end

      # Get the first license in the list
      license_uri = license_data["Members"][0]["@odata.id"]
      debug "Using license URI: #{license_uri}", 2

      # Get detailed license information
      license_response = authenticated_request(:get, license_uri)
      if license_response.status != 200
        debug "Failed to retrieve license details: #{license_response.status}", 1, :red
        return nil
      end

      license_details = JSON.parse(license_response.body)
      debug "License details: #{license_details}", 2

      return RecursiveOpenStruct.new(license_details, recurse_over_arrays: true)
    end

    # Extracts the iDRAC version from the license description
    # @return [Integer, nil] The license version (e.g. 9) or nil if not found
    def license_version
      license = license_info
      return nil unless license

      # Check the Description field, which often contains the version
      # Example: "iDRAC9 Enterprise License"
      if license.Description && license.Description.match(/iDRAC(\d+)/i)
        version = license.Description.match(/iDRAC(\d+)/i)[1].to_i
        debug "Found license version from Description: #{version}", 1
        return version
      end

      # Try alternative fields if Description didn't work
      if license.Name && license.Name.match(/iDRAC(\d+)/i)
        version = license.Name.match(/iDRAC(\d+)/i)[1].to_i
        debug "Found license version from Name: #{version}", 1
        return version
      end

      debug "Could not determine license version from license info", 1, :yellow
      nil
    end
  end
end 