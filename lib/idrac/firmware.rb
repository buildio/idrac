require 'tempfile'
require 'net/http'
require 'uri'
require 'json'
require 'nokogiri'
require 'fileutils'
require 'securerandom'
require 'set'
require 'colorize'
require_relative 'firmware_catalog'
require 'faraday'
require 'faraday/multipart'

module IDRAC
  class Firmware
    attr_reader :client

    CATALOG_URL = "https://downloads.dell.com/catalog/Catalog.xml.gz"
    
    def initialize(client)
      @client = client
    end

    def update(firmware_path, options = {})
      # Validate firmware file exists
      unless File.exist?(firmware_path)
        raise Error, "Firmware file not found: #{firmware_path}"
      end

      # Ensure we have a client
      raise Error, "Client is required for firmware update" unless client

      # Login to iDRAC
      client.login unless client.instance_variable_get(:@session_id)

      # Upload firmware file
      job_id = upload_firmware(firmware_path)
      
      # Check if we should wait for the update to complete
      if options[:wait]
        wait_for_job_completion(job_id, options[:timeout] || 3600)
      end

      job_id
    end
    
    def download_catalog(output_dir = nil)
      # Use the new FirmwareCatalog class
      catalog = FirmwareCatalog.new
      catalog.download(output_dir)
    end
    
    def get_system_inventory
      # Ensure we have a client
      raise Error, "Client is required for system inventory" unless client
      
      puts "Retrieving system inventory..."
      
      # Get basic system information
      system_uri = URI.parse("#{client.base_url}/redfish/v1/Systems/System.Embedded.1")
      system_response = client.authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if system_response.status != 200
        raise Error, "Failed to get system information: #{system_response.status}"
      end
      
      system_data = JSON.parse(system_response.body)
      
      # Get firmware inventory
      firmware_uri = URI.parse("#{client.base_url}/redfish/v1/UpdateService/FirmwareInventory")
      firmware_response = client.authenticated_request(:get, "/redfish/v1/UpdateService/FirmwareInventory")
      
      if firmware_response.status != 200
        raise Error, "Failed to get firmware inventory: #{firmware_response.status}"
      end
      
      firmware_data = JSON.parse(firmware_response.body)
      
      # Get detailed firmware information for each component
      firmware_inventory = []
      
      if firmware_data['Members'] && firmware_data['Members'].is_a?(Array)
        firmware_data['Members'].each do |member|
          if member['@odata.id']
            component_uri = member['@odata.id']
            component_response = client.authenticated_request(:get, component_uri)
            
            if component_response.status == 200
              component_data = JSON.parse(component_response.body)
              firmware_inventory << {
                name: component_data['Name'],
                id: component_data['Id'],
                version: component_data['Version'],
                updateable: component_data['Updateable'] || false,
                status: component_data['Status'] ? component_data['Status']['State'] : 'Unknown'
              }
            end
          end
        end
      end
      
      {
        system: {
          model: system_data['Model'],
          manufacturer: system_data['Manufacturer'],
          serial_number: system_data['SerialNumber'],
          part_number: system_data['PartNumber'],
          bios_version: system_data['BiosVersion'],
          service_tag: system_data['SKU']
        },
        firmware: firmware_inventory
      }
    end
    
    def check_updates(catalog_path = nil)
      # Ensure we have a client for system inventory
      raise Error, "Client is required for checking updates" unless client
      
      # Download catalog if not provided
      catalog_path ||= download_catalog
      
      # Get system inventory
      inventory = get_system_inventory
      
      # Create a FirmwareCatalog instance
      catalog = FirmwareCatalog.new(catalog_path)
      
      # Extract system information
      system_model = inventory[:system][:model]
      service_tag = inventory[:system][:service_tag]
      
      puts "Checking updates for system with service tag: #{service_tag}".light_cyan
      puts "Searching for updates for model: #{system_model}".light_cyan
      
      # Find system models in the catalog
      models = catalog.find_system_models(system_model)
      
      if models.empty?
        puts "No matching system model found in catalog".yellow
        return []
      end
      
      # Use the first matching model
      model = models.first
      puts "Found system IDs for #{model[:name]}: #{model[:id]}".green
      
      # Find updates for this system
      catalog_updates = catalog.find_updates_for_system(model[:id])
      puts "Found #{catalog_updates.size} firmware updates for #{model[:name]}".green
      
      # Compare current firmware with available updates
      updates = []
      
      # Print header for firmware comparison table
      puts "\nFirmware Version Comparison:".green.bold
      puts "=" * 100
      puts "%-30s %-20s %-20s %-10s %-15s %s" % ["Component", "Current Version", "Available Version", "Updateable", "Category", "Status"]
      puts "-" * 100
      
      # Track components we've already displayed to avoid duplicates
      displayed_components = Set.new
      
      # First show current firmware with available updates
      inventory[:firmware].each do |fw|
        # Make sure firmware name is not nil
        firmware_name = fw[:name] || ""
        
        # Skip if we've already displayed this component
        next if displayed_components.include?(firmware_name.downcase)
        displayed_components.add(firmware_name.downcase)
        
        # Extract key identifiers from the firmware name
        identifiers = extract_identifiers(firmware_name)
        
        # Try to find a matching update
        matching_updates = catalog_updates.select do |update|
          update_name = update[:name] || ""
          
          # Check if any of our identifiers match the update name
          identifiers.any? { |id| update_name.downcase.include?(id.downcase) } ||
          # Or if the update name contains the firmware name
          update_name.downcase.include?(firmware_name.downcase) ||
          # Or if the firmware name contains the update name
          firmware_name.downcase.include?(update_name.downcase)
        end
        
        if matching_updates.any?
          # Use the first matching update
          update = matching_updates.first
          
          # Check if version is newer
          needs_update = catalog.compare_versions(fw[:version], update[:version])
          
          # Add to updates list if needed
          if needs_update && fw[:updateable]
            updates << {
              name: fw[:name],
              current_version: fw[:version],
              available_version: update[:version],
              path: update[:path],
              component_type: update[:component_type],
              category: update[:category],
              download_url: update[:download_url]
            }
            
            # Print row with update available
            puts "%-30s %-20s %-20s %-10s %-15s %s" % [
              fw[:name].to_s[0..29],
              fw[:version],
              update[:version],
              fw[:updateable] ? "Yes".light_green : "No".light_red,
              update[:category] || "N/A",
              "UPDATE AVAILABLE".light_green.bold
            ]
          else
            # Print row with no update needed
            status = if !needs_update
                       "Current".light_blue
                     elsif !fw[:updateable]
                       "Not updateable".light_red
                     else
                       "No update needed".light_yellow
                     end
            
            puts "%-30s %-20s %-20s %-10s %-15s %s" % [
              fw[:name].to_s[0..29],
              fw[:version],
              update[:version] || "N/A",
              fw[:updateable] ? "Yes".light_green : "No".light_red,
              update[:category] || "N/A",
              status
            ]
          end
        else
          # No matching update found
          puts "%-30s %-20s %-20s %-10s %-15s %s" % [
            fw[:name].to_s[0..29],
            fw[:version],
            "N/A",
            fw[:updateable] ? "Yes".light_green : "No".light_red,
            "N/A",
            "No update available".light_yellow
          ]
        end
      end
      
      # Then show available updates that don't match any current firmware
      catalog_updates.each do |update|
        update_name = update[:name] || ""
        
        # Skip if we've already displayed this component
        next if displayed_components.include?(update_name.downcase)
        displayed_components.add(update_name.downcase)
        
        # Skip if this update was already matched to a current firmware
        next if inventory[:firmware].any? do |fw|
          firmware_name = fw[:name] || ""
          identifiers = extract_identifiers(firmware_name)
          
          identifiers.any? { |id| update_name.downcase.include?(id.downcase) } ||
          update_name.downcase.include?(firmware_name.downcase) ||
          firmware_name.downcase.include?(update_name.downcase)
        end
        
        puts "%-30s %-20s %-20s %-10s %-15s %s" % [
          update_name.to_s[0..29],
          "Not Installed".light_red,
          update[:version] || "Unknown",
          "N/A",
          update[:category] || "N/A",
          "NEW COMPONENT".light_blue
        ]
      end
      
      puts "=" * 100
      
      updates
    end
    
    def interactive_update(catalog_path = nil, selected_updates = nil)
      # Check if updates are available
      updates = selected_updates || check_updates(catalog_path)
      
      if updates.empty?
        puts "No updates available for your system.".yellow
        return
      end
      
      # Display available updates
      puts "\nAvailable Updates:".green.bold
      updates.each_with_index do |update, index|
        puts "#{index + 1}. #{update[:name]}: #{update[:current_version]} -> #{update[:available_version]}".light_cyan
      end
      
      # If no specific updates were selected, ask the user which ones to install
      if selected_updates.nil?
        puts "\nEnter the number of the update to install (or 'all' for all updates, 'q' to quit):".light_yellow
        input = STDIN.gets.chomp
        
        if input.downcase == 'q'
          puts "Update cancelled.".yellow
          return
        elsif input.downcase == 'all'
          selected_updates = updates
        else
          begin
            index = input.to_i - 1
            if index >= 0 && index < updates.length
              selected_updates = [updates[index]]
            else
              puts "Invalid selection. Please enter a number between 1 and #{updates.length}.".red
              return
            end
          rescue
            puts "Invalid input. Please enter a number, 'all', or 'q'.".red
            return
          end
        end
      end
      
      # Process each selected update
      selected_updates.each do |update|
        puts "\nDownloading #{update[:name]} version #{update[:available_version]}...".light_cyan
        
        begin
          # Download the firmware
          firmware_file = download_firmware(update)
          
          if firmware_file
            puts "Installing #{update[:name]} version #{update[:available_version]}...".light_cyan
            
            begin
              # Upload and install the firmware
              job_id = upload_firmware(firmware_file)
              
              if job_id
                puts "Firmware update job created with ID: #{job_id}".green
                
                # Wait for the job to complete
                success = wait_for_job_completion(job_id, 1800) # 30 minutes timeout
                
                if success
                  puts "Successfully updated #{update[:name]} to version #{update[:available_version]}".green.bold
                else
                  puts "Failed to update #{update[:name]}. Check the iDRAC web interface for more details.".red
                  puts "You may need to wait for any existing jobs to complete before trying again.".yellow
                end
              else
                puts "Failed to create update job for #{update[:name]}".red
              end
            rescue IDRAC::Error => e
              if e.message.include?("already in progress")
                puts "Error: A firmware update is already in progress.".red.bold
                puts "Please wait for the current update to complete before starting another.".yellow
                puts "You can check the status in the iDRAC web interface under Maintenance > System Update.".light_cyan
              elsif e.message.include?("job ID not found") || e.message.include?("Failed to get job status")
                puts "Error: Could not monitor the update job.".red.bold
                puts "The update may still be in progress. Check the iDRAC web interface for status.".yellow
                puts "This can happen if the iDRAC is busy processing the update request.".light_cyan
              else
                puts "Error during firmware update: #{e.message}".red.bold
              end
              
              # If we encounter an error with one update, ask if the user wants to continue with others
              if selected_updates.length > 1 && update != selected_updates.last
                puts "\nDo you want to continue with the remaining updates? (y/n)".light_yellow
                continue = STDIN.gets.chomp.downcase
                break unless continue == 'y'
              end
            end
          else
            puts "Failed to download firmware for #{update[:name]}".red
          end
        rescue => e
          puts "Error processing update for #{update[:name]}: #{e.message}".red.bold
          
          # If we encounter an error with one update, ask if the user wants to continue with others
          if selected_updates.length > 1 && update != selected_updates.last
            puts "\nDo you want to continue with the remaining updates? (y/n)".light_yellow
            continue = STDIN.gets.chomp.downcase
            break unless continue == 'y'
          end
        ensure
          # Clean up temporary files
          FileUtils.rm_f(firmware_file) if firmware_file && File.exist?(firmware_file)
        end
      end
    end

    def download_firmware(update)
      return false unless update && update[:download_url]
      
      begin
        # Create a temporary directory for the download
        temp_dir = Dir.mktmpdir
        
        # Extract the filename from the path
        filename = File.basename(update[:path])
        local_path = File.join(temp_dir, filename)
        
        puts "Downloading firmware from #{update[:download_url]}".light_cyan
        puts "Saving to #{local_path}".light_cyan
        
        # Download the file
        uri = URI.parse(update[:download_url])
        
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
          request = Net::HTTP::Get.new(uri)
          
          http.request(request) do |response|
            if response.code == "200"
              File.open(local_path, 'wb') do |file|
                response.read_body do |chunk|
                  file.write(chunk)
                end
              end
              
              puts "Download completed successfully".green
              return local_path
            else
              puts "Failed to download firmware: #{response.code} #{response.message}".red
              return false
            end
          end
        end
      rescue => e
        puts "Error downloading firmware: #{e.message}".red.bold
        return false
      end
    end

    def get_power_state
      # Ensure we have a client
      raise Error, "Client is required for power management" unless client
      
      # Login to iDRAC if needed
      client.login unless client.instance_variable_get(:@session_id)
      
      # Get system information
      response = client.authenticated_request(:get, "/redfish/v1/Systems/System.Embedded.1")
      
      if response.status == 200
        system_data = JSON.parse(response.body)
        return system_data["PowerState"]
      else
        raise Error, "Failed to get power state. Status code: #{response.status}"
      end
    end

    private

    def upload_firmware(firmware_path)
      puts "Uploading firmware file: #{firmware_path}".light_cyan
      
      begin
        # First, get the HttpPushUri from the UpdateService
        response = client.authenticated_request(
          :get,
          "/redfish/v1/UpdateService"
        )
        
        if response.status != 200
          puts "Failed to get UpdateService information: #{response.status}".red
          raise Error, "Failed to get UpdateService information: #{response.status}"
        end
        
        update_service = JSON.parse(response.body)
        http_push_uri = update_service['HttpPushUri']
        
        if http_push_uri.nil?
          puts "HttpPushUri not found in UpdateService".red
          raise Error, "HttpPushUri not found in UpdateService"
        end
        
        puts "Found HttpPushUri: #{http_push_uri}".light_cyan
        
        # Get the ETag for the firmware inventory
        etag_response = client.authenticated_request(
          :get,
          http_push_uri
        )
        
        if etag_response.status != 200
          puts "Failed to get ETag: #{etag_response.status}".red
          raise Error, "Failed to get ETag: #{etag_response.status}"
        end
        
        etag = etag_response.headers['ETag']
        
        if etag.nil?
          puts "ETag not found in response headers".yellow
          # Some iDRACs don't require ETag, so we'll continue
        else
          puts "Got ETag: #{etag}".light_cyan
        end
        
        # Upload the firmware file
        file_content = File.read(firmware_path)
        
        headers = {
          'Content-Type' => 'multipart/form-data',
          'If-Match' => etag
        }
        
        # Create a temp file for multipart upload
        upload_io = Faraday::UploadIO.new(firmware_path, 'application/octet-stream')
        payload = { :file => upload_io }
        
        upload_response = client.authenticated_request(
          :post,
          http_push_uri,
          {
            headers: headers,
            body: payload,
          }
        )
        
        if upload_response.status != 201 && upload_response.status != 200
          puts "Failed to upload firmware: #{upload_response.status} - #{upload_response.body}".red
          
          if upload_response.body.include?("already in progress")
            raise Error, "A deployment or update operation is already in progress. Please wait for it to complete before attempting another update."
          else
            raise Error, "Failed to upload firmware: #{upload_response.status} - #{upload_response.body}"
          end
        end
        
        # Extract the firmware ID from the response
        begin
          upload_data = JSON.parse(upload_response.body)
          firmware_id = upload_data['Id'] || upload_data['@odata.id']&.split('/')&.last
          
          if firmware_id.nil?
            # Try to extract from the Location header
            location = upload_response.headers['Location']
            firmware_id = location&.split('/')&.last
          end
          
          if firmware_id.nil?
            puts "Warning: Could not extract firmware ID from response".yellow
            puts "Response body: #{upload_response.body}"
            # We'll try to continue with the SimpleUpdate action anyway
          else
            puts "Firmware file uploaded successfully with ID: #{firmware_id}".green
          end
        rescue JSON::ParserError => e
          puts "Warning: Could not parse upload response: #{e.message}".yellow
          puts "Response body: #{upload_response.body}"
          # We'll try to continue with the SimpleUpdate action anyway
        end
        
        # Now initiate the firmware update using SimpleUpdate action
        puts "Initiating firmware update using SimpleUpdate...".light_cyan
        
        # Construct the image URI
        image_uri = nil
        
        if firmware_id
          image_uri = "#{http_push_uri}/#{firmware_id}"
        else
          # If we couldn't extract the firmware ID, try using the Location header
          image_uri = upload_response.headers['Location']
        end
        
        # If we still don't have an image URI, try to use the HTTP push URI as a fallback
        if image_uri.nil?
          puts "Warning: Could not determine image URI, using HTTP push URI as fallback".yellow
          image_uri = http_push_uri
        end
        
        puts "Using ImageURI: #{image_uri}".light_cyan
        
        # Initiate the SimpleUpdate action
        simple_update_payload = {
          "ImageURI" => image_uri,
          "TransferProtocol" => "HTTP"
        }
        
        update_response = client.authenticated_request(
          :post,
          "/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate",
          {
            headers: { 'Content-Type' => 'application/json' },
            body: simple_update_payload.to_json
          }
        )
        
        if update_response.status != 202 && update_response.status != 200
          puts "Failed to initiate firmware update: #{update_response.status} - #{update_response.body}".red
          raise Error, "Failed to initiate firmware update: #{update_response.status} - #{update_response.body}"
        end
        
        # Extract the job ID from the response
        job_id = nil
        
        # Try to extract from the response body first
        begin
          update_data = JSON.parse(update_response.body)
          job_id = update_data['Id'] || update_data['JobID']
        rescue JSON::ParserError
          # If we can't parse the body, that's okay, we'll try other methods
        end
        
        # If we couldn't get the job ID from the body, try the Location header
        if job_id.nil?
          location = update_response.headers['Location']
          job_id = location&.split('/')&.last
        end
        
        # If we still don't have a job ID, try the response headers
        if job_id.nil?
          # Some iDRACs return the job ID in a custom header
          update_response.headers.each do |key, value|
            if key.downcase.include?('job') && value.is_a?(String) && value.match?(/JID_\d+/)
              job_id = value
              break
            end
          end
        end
        
        # If we still don't have a job ID, check for any JID_ pattern in the response body
        if job_id.nil? && update_response.body.is_a?(String)
          match = update_response.body.match(/JID_\d+/)
          job_id = match[0] if match
        end
        
        # If we still don't have a job ID, check the task service for recent jobs
        if job_id.nil?
          puts "Could not extract job ID from response, checking task service for recent jobs...".yellow
          
          tasks_response = client.authenticated_request(
            :get,
            "/redfish/v1/TaskService/Tasks"
          )
          
          if tasks_response.status == 200
            begin
              tasks_data = JSON.parse(tasks_response.body)
              
              if tasks_data['Members'] && tasks_data['Members'].any?
                # Get the most recent task
                most_recent_task = tasks_data['Members'].first
                task_id = most_recent_task['@odata.id']&.split('/')&.last
                
                if task_id && task_id.match?(/JID_\d+/)
                  job_id = task_id
                  puts "Found recent job ID: #{job_id}".light_cyan
                end
              end
            rescue JSON::ParserError
              # If we can't parse the tasks response, we'll have to give up
            end
          end
        end
        
        if job_id.nil?
          puts "Could not extract job ID from response".red
          raise Error, "Could not extract job ID from response"
        end
        
        puts "Firmware update job created with ID: #{job_id}".green
        return job_id
      rescue => e
        puts "Error during firmware upload: #{e.message}".red.bold
        raise Error, "Error during firmware upload: #{e.message}"
      end
    end

    def wait_for_job_completion(job_id, timeout)
      puts "Waiting for firmware update job #{job_id} to complete...".light_cyan
      
      start_time = Time.now
      last_percent = -1
      
      while Time.now - start_time < timeout
        begin
          status = get_job_status(job_id)
          
          # Only show percentage updates when they change
          if status[:percent_complete] && status[:percent_complete] != last_percent
            puts "Job progress: #{status[:percent_complete]}% complete".light_cyan
            last_percent = status[:percent_complete]
          end
          
          case status[:state]
          when 'Completed'
            puts "Firmware update completed successfully".green
            return true
          when 'Failed', 'CompletedWithErrors'
            message = status[:message] || "Unknown error"
            puts "Firmware update failed: #{message}".red.bold
            return false
          when 'Stopped'
            puts "Firmware update stopped".yellow
            return false
          when 'New', 'Starting', 'Running', 'Pending', 'Scheduled', 'Downloaded', 'Downloading', 'Staged'
            # Job still in progress, continue waiting
            sleep 10
          else
            puts "Unknown job status: #{status[:state]}".yellow
            sleep 10
          end
        rescue => e
          puts "Error checking job status: #{e.message}".red
          puts "Will retry in 15 seconds...".yellow
          sleep 15
        end
      end
      
      puts "Timeout waiting for firmware update to complete".red.bold
      false
    end

    def get_job_status(job_id)
      response = client.authenticated_request(
        :get,
        "/redfish/v1/TaskService/Tasks/#{job_id}"
      )
      
      # Status 202 means the request was accepted but still processing
      # This is normal for jobs that are in progress
      if response.status == 202 || response.status == 200
        begin
          data = JSON.parse(response.body)
          
          # Extract job state and percent complete
          job_state = data.dig('Oem', 'Dell', 'JobState') || data['TaskState']
          percent_complete = data.dig('Oem', 'Dell', 'PercentComplete') || data['PercentComplete']
          
          # Format the percent complete for display
          percent_str = percent_complete.nil? ? "unknown" : "#{percent_complete}%"
          
          puts "Job #{job_id} status: #{job_state} (#{percent_str} complete)".light_cyan
          
          return {
            id: job_id,
            state: job_state,
            percent_complete: percent_complete,
            status: data['TaskStatus'],
            message: data.dig('Oem', 'Dell', 'Message') || (data['Messages'].first && data['Messages'].first['Message']),
            raw_data: data
          }
        rescue JSON::ParserError => e
          puts "Error parsing job status response: #{e.message}".red.bold
          raise Error, "Failed to parse job status response: #{e.message}"
        end
      else
        puts "Failed to get job status with status #{response.status}: #{response.body}".red
        raise Error, "Failed to get job status with status #{response.status}"
      end
    end

    # Helper method to extract identifiers from component names
    def extract_identifiers(name)
      return [] unless name
      
      identifiers = []
      
      # Extract model numbers like X520, I350, etc.
      model_matches = name.scan(/[IX]\d{3,4}/)
      identifiers.concat(model_matches)
      
      # Extract PERC model like H730
      perc_matches = name.scan(/[HP]\d{3,4}/)
      identifiers.concat(perc_matches)
      
      # Extract other common identifiers
      if name.include?("NIC") || name.include?("Ethernet") || name.include?("Network")
        identifiers << "NIC"
      end
      
      if name.include?("PERC") || name.include?("RAID")
        identifiers << "PERC"
        # Extract PERC model like H730
        perc_match = name.match(/PERC\s+([A-Z]\d{3})/)
        identifiers << perc_match[1] if perc_match
      end
      
      if name.include?("BIOS")
        identifiers << "BIOS"
      end
      
      if name.include?("iDRAC") || name.include?("IDRAC") || name.include?("Remote Access Controller")
        identifiers << "iDRAC"
      end
      
      if name.include?("Power Supply") || name.include?("PSU")
        identifiers << "PSU"
      end
      
      if name.include?("Lifecycle Controller")
        identifiers << "LC"
      end
      
      if name.include?("CPLD")
        identifiers << "CPLD"
      end
      
      identifiers
    end
  end
end 