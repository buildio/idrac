
module IDRAC
  module Utility
    include Debuggable

    # Generate TSR (Technical Support Report) logs using SupportAssistCollection for local generation
    # @param data_selector_values [Array] Array of log types to include (optional)
    #   Default includes all available log types
    # @return [Hash] Result hash with status and job/task information
    def generate_tsr_logs(data_selector_values: nil, share_type: nil, share_parameters: nil)
      debug "Generating TSR/SupportAssist logs...", 1
      
      # Check EULA status first
      eula_status = supportassist_eula_status
      if eula_status["EULAAccepted"] == false || eula_status["EULAAccepted"] == "false"
        puts "\n" + "="*80
        puts "ERROR: SupportAssist EULA Not Accepted".red.bold
        puts "="*80
        puts ""
        puts "The SupportAssist End User License Agreement (EULA) must be accepted".yellow
        puts "before you can generate TSR/SupportAssist collections.".yellow
        puts ""
        puts "To accept the EULA, run:".cyan
        puts "  idrac tsr_accept_eula --host #{@host} --port #{@port}".green.bold
        puts ""
        puts "="*80
        return { status: :failed, error: "SupportAssist EULA not accepted" }
      end
      
      # Default data selector values for comprehensive TSR
      # Valid values for SupportAssistCollection: "DebugLogs", "GPULogs", "HWData", "OSAppData", "TTYLogs", "TelemetryReports"
      data_selector_values ||= ["HWData", "OSAppData"]  
      
      # Map numeric values to iDRAC expected strings if needed
      if data_selector_values.is_a?(Array) && data_selector_values.first.to_s =~ /^\d+$/
        data_selector_values = data_selector_values.map do |val|
          case val.to_s
          when "0" then "HWData"
          when "1" then "OSAppData"  
          when "2" then "TTYLogs"
          when "3" then "DebugLogs"
          else "HWData"  # Default to HWData
          end
        end
      elsif data_selector_values.is_a?(String)
        data_selector_values = data_selector_values.split(',')
      end
      
      debug "Data selector values: #{data_selector_values.inspect}", 1
      
      # Use SupportAssistCollection for local generation as it supports "Local" ShareType
      payload = {
        "ShareType" => "Local",
        "DataSelectorArrayIn" => data_selector_values,
        "Filter" => "No",  # Don't filter PII
        "Transmit" => "No"  # Don't transmit to Dell
      }
      
      debug "SupportAssist collection payload: #{payload.to_json}", 1
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.SupportAssistCollection",
        body: payload.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      
      case response.status
      when 202
        # Accepted - job created
        location = response.headers["location"]
        if location
          debug "TSR generation job created: #{location}", 1, :green
          job_id = location.split("/").last
          # Wait for job to complete and capture the file location
          job_result = wait_for_job_with_location(job_id)
          if job_result && (job_result["JobState"] == "Completed" || job_result["JobState"] == "CompletedWithErrors")
            result = { status: :success, job: job_result }
            # Check if we got a file location from the job completion
            result[:location] = job_result["FileLocation"] if job_result["FileLocation"]
            result
          else
            { status: :failed, error: "Job did not complete successfully" }
          end
        else
          { status: :accepted, message: "TSR generation initiated" }
        end
      when 200..299
        debug "TSR generation completed immediately", 1, :green
        { status: :success }
      else
        error_msg = parse_error_response(response)
        debug "Failed to generate TSR: #{error_msg}", 1, :red
        { status: :failed, error: error_msg }
      end
    rescue => e
      debug "Error generating TSR: #{e.message}", 1, :red
      { status: :error, error: e.message }
    end

    # Download TSR/SupportAssist logs from a URL location
    # @param location [String] URL location of the TSR file
    # @param output_file [String] Path to save the TSR file (optional)
    # @return [String, nil] Path to downloaded file or nil if failed
    def download_tsr_from_location(location, output_file: nil)
      debug "Downloading TSR from location: #{location}", 1
      
      # Default output filename with timestamp
      output_file ||= "supportassist_#{@host}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.zip"
      
      # Download the file from the location
      file_response = authenticated_request(:get, location)
      
      if file_response.status == 200 && file_response.body
        File.open(output_file, 'wb') do |f|
          f.write(file_response.body)
        end
        debug "TSR saved to: #{output_file} (#{File.size(output_file)} bytes)", 1, :green
        return output_file
      else
        debug "Failed to download file from location. Status: #{file_response.status}", 1, :red
        nil
      end
    rescue => e
      debug "Error downloading TSR: #{e.message}", 1, :red
      nil
    end
    
    # Wait for job and capture file location from response headers
    # @param job_id [String] The job ID to wait for
    # @param max_wait [Integer] Maximum time to wait in seconds
    # @return [Hash, nil] Job data with FileLocation if available
    def wait_for_job_with_location(job_id, max_wait: 600)
      debug "Waiting for job #{job_id} to complete...", 1
      start_time = Time.now
      
      while (Time.now - start_time) < max_wait
        job_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/#{job_id}")
        
        if job_response.status == 200
          job_data = JSON.parse(job_response.body)
          
          case job_data["JobState"]
          when "Completed", "CompletedWithErrors"
            debug "Job #{job_id} completed: #{job_data["JobState"]}", 1, :green
            
            # Check response headers for file location
            if job_response.headers["location"]
              job_data["FileLocation"] = job_response.headers["location"]
              debug "Found file location in headers: #{job_data["FileLocation"]}", 1, :green
            end
            
            # Also check the job data itself for output location
            if job_data["Oem"] && job_data["Oem"]["Dell"] && job_data["Oem"]["Dell"]["OutputLocation"]
              job_data["FileLocation"] = job_data["Oem"]["Dell"]["OutputLocation"]
              debug "Found file location in job data: #{job_data["FileLocation"]}", 1, :green
            end
            
            return job_data
          when "Failed", "Exception"
            debug "Job #{job_id} failed: #{job_data["Message"]}", 1, :red
            return job_data
          else
            debug "Job #{job_id} state: #{job_data["JobState"]} - #{job_data["PercentComplete"]}%", 2
            sleep 5
          end
        else
          debug "Failed to get job status: #{job_response.status}", 2
          sleep 5
        end
      end
      
      debug "Timeout waiting for job #{job_id}", 1, :red
      nil
    end
    
    # Parse error response from iDRAC
    def parse_error_response(response)
      begin
        data = JSON.parse(response.body)
        if data["error"] && data["error"]["@Message.ExtendedInfo"]
          data["error"]["@Message.ExtendedInfo"].first["Message"]
        elsif data["error"] && data["error"]["message"]
          data["error"]["message"]
        else
          "Status: #{response.status} - #{response.body}"
        end
      rescue
        "Status: #{response.status} - #{response.body}"
      end
    end

    # Generate and download TSR logs in a single operation
    # @param output_file [String] Path to save the TSR file (optional)
    # @param data_selector_values [Array] Array of log types to include (optional)
    # @param wait_timeout [Integer] Maximum time to wait for generation in seconds (default: 600)
    # @return [String, nil] Path to downloaded file or nil if failed
    def generate_and_download_tsr(output_file: nil, data_selector_values: nil, wait_timeout: 600)
      debug "Starting TSR generation and download process...", 1
      
      output_file ||= "supportassist_#{@host}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.zip"
      
      # First, generate the TSR
      result = generate_tsr_logs(data_selector_values: data_selector_values)
      
      if result[:status] == :success && result[:job]
        debug "TSR generation completed successfully", 1, :green
        
        # Check if the job response has a location for the file
        if result[:location]
          return download_tsr_from_location(result[:location], output_file: output_file)
        else
          # Try alternative download methods based on Dell's Python script approach
          debug "Attempting to locate generated TSR file...", 1, :yellow
          
          # Wait a moment for the file to be available
          sleep 2
          
          # Try known endpoints where the file might be available
          possible_locations = [
            "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/ExportedFiles/SupportAssist",
            "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLCService/ExportedFiles",
            "/downloads/supportassist_collection.zip",
            "/sysmgmt/2016/server/support_assist_collection"
          ]
          
          possible_locations.each do |location|
            debug "Trying location: #{location}", 2
            file_response = authenticated_request(:get, location)
            
            if file_response.status == 200 && file_response.body && file_response.body.size > 1024
              File.open(output_file, 'wb') do |f|
                f.write(file_response.body)
              end
              debug "TSR saved to: #{output_file} (#{File.size(output_file)} bytes)", 1, :green
              return output_file
            end
          end
          
          debug "Could not locate TSR file for direct download", 1, :yellow
          debug "The collection was generated but may require network share export", 1, :yellow
        end
      elsif result[:status] == :accepted
        debug "TSR generation was accepted but status unknown", 1, :yellow
      else
        debug "Failed to initiate TSR generation: #{result[:error]}", 1, :red
      end
      
      nil
    end
    public

    # Get TSR/SupportAssist collection status
    # @return [Hash] Status information
    def tsr_status
      debug "Checking SupportAssist collection status...", 1
      
      response = authenticated_request(
        :get,
        "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService"
      )
      
      if response.status == 200
        data = JSON.parse(response.body)
        status = {
          available: data["Actions"]&.key?("#DellLCService.SupportAssistCollection"),
          export_available: data["Actions"]&.key?("#DellLCService.SupportAssistExportLastCollection"),
          collection_in_progress: false
        }
        
        # Check if there's an active collection job
        jobs_response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs")
        if jobs_response.status == 200
          jobs_data = JSON.parse(jobs_response.body)
          if jobs_data["Members"]
            jobs_data["Members"].each do |job|
              if job["Name"]&.include?("SupportAssist") || job["Name"]&.include?("TSR")
                status[:collection_in_progress] = true
                status[:job_id] = job["Id"]
                status[:job_state] = job["JobState"]
                break
              end
            end
          end
        end
        
        debug "SupportAssist status: #{status.to_json}", 2
        status
      else
        debug "Failed to get SupportAssist status: #{response.status}", 1, :red
        { available: false, error: "Unable to determine status" }
      end
    rescue => e
      debug "Error checking SupportAssist status: #{e.message}", 1, :red
      { available: false, error: e.message }
    end

    # Check SupportAssist EULA status
    # @return [Hash] EULA status information
    def supportassist_eula_status
      debug "Checking SupportAssist EULA status...", 1
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.SupportAssistGetEULAStatus",
        body: {}.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        begin
          data = JSON.parse(response.body)
          debug "EULA status: #{data.to_json}", 2
          return data
        rescue JSON::ParserError
          return { "EULAAccepted" => "Unknown" }
        end
      else
        error_msg = parse_error_response(response)
        debug "Failed to get EULA status: #{error_msg}", 1, :red
        return { "EULAAccepted" => "Error", "error" => error_msg }
      end
    rescue => e
      debug "Error checking EULA status: #{e.message}", 1, :red
      { "EULAAccepted" => "Error", "error" => e.message }
    end
    
    # Accept SupportAssist EULA
    # @return [Boolean] true if successful
    def accept_supportassist_eula
      debug "Accepting SupportAssist EULA...", 1
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.SupportAssistAcceptEULA",
        body: {}.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        debug "SupportAssist EULA accepted successfully", 1, :green
        true
      else
        error_msg = parse_error_response(response)
        debug "Failed to accept EULA: #{error_msg}", 1, :red
        false
      end
    rescue => e
      debug "Error accepting EULA: #{e.message}", 1, :red
      false
    end
    
    # Reset the iDRAC controller (graceful restart)
    def reset!
      debug "Resetting iDRAC controller...", 1
      
      response = authenticated_request(
        :post,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset",
        body: { "ResetType" => "GracefulRestart" }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        debug "Reset command accepted, waiting for iDRAC to restart...", 1, :green
        tries = 0
        
        while true
          begin
            debug "Checking if iDRAC is back online...", 1
            response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1")
            if response.status.between?(200, 299)
              debug "iDRAC is back online!", 1, :green
              break
            end
            sleep 30
          rescue => e
            tries += 1
            if tries > 5
              debug "Failed to reconnect to iDRAC after 5 attempts", 1, :red
              return false
            end
            debug "No response from server... retry #{tries}/5", 1, :red
            sleep 2 ** tries
          end
        end
      else
        begin
          error_data = JSON.parse(response.body)
          if error_data["error"] && error_data["error"]["@Message.ExtendedInfo"]
            message = error_data["error"]["@Message.ExtendedInfo"].first["Message"]
            debug "*" * 80, 1, :red
            debug message, 1, :red
            debug "*" * 80, 1, :red
          else
            debug "Failed to reset iDRAC. Status code: #{response.status}", 1, :red
          end
        rescue => e
          debug "Failed to reset iDRAC. Status code: #{response.status}", 1, :red
          debug "Error response: #{response.body}", 2, :red
        end
        return false
      end
      
      true
    end
  end
end 