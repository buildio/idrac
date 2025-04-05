require 'json'
require 'colorize'

module IDRAC
  module Jobs
    # Get a list of jobs
    def jobs
      response = authenticated_request(:get, '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)')
      
      if response.status == 200
        begin
          jobs_data = JSON.parse(response.body)
          puts "Jobs: #{jobs_data['Members'].count}"
          if jobs_data['Members'].count > 0
            puts "Job IDs:"
            jobs_data["Members"].each do |job|
              puts "  #{job['Id']}"
            end
          end
          return jobs_data
        rescue JSON::ParserError
          raise Error, "Failed to parse jobs response: #{response.body}"
        end
      else
        raise Error, "Failed to get jobs. Status code: #{response.status}"
      end
    end
    
    # Get detailed job information
    def jobs_detail
      response = authenticated_request(:get, '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)')
      
      if response.status == 200
        begin
          jobs_data = JSON.parse(response.body)
          jobs_data["Members"].each do |job| 
            puts "#{job['Id']} : #{job['JobState']} > #{job['Message']}" 
          end
          return jobs_data
        rescue JSON::ParserError
          raise Error, "Failed to parse jobs detail response: #{response.body}"
        end
      else
        raise Error, "Failed to get jobs detail. Status code: #{response.status}"
      end
    end
    
    # Clear all jobs from the job queue
    def clear_jobs!
      # Get list of jobs
      jobs_response = authenticated_request(:get, '/redfish/v1/Managers/iDRAC.Embedded.1/Jobs?$expand=*($levels=1)')
      
      if jobs_response.status == 200
        begin
          jobs_data = JSON.parse(jobs_response.body)
          members = jobs_data["Members"]
          
          # Delete each job individually
          members.each.with_index do |job, i|
            puts "Removing #{job['Id']} [#{i+1}/#{members.count}]"
            delete_response = authenticated_request(:delete, "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/#{job['Id']}")
            
            unless delete_response.status.between?(200, 299)
              puts "Warning: Failed to delete job #{job['Id']}. Status code: #{delete_response.status}".yellow
            end
          end
          
          puts "Successfully cleared all jobs".green
          return true
        rescue JSON::ParserError
          raise Error, "Failed to parse jobs response: #{jobs_response.body}"
        end
      else
        raise Error, "Failed to get jobs. Status code: #{jobs_response.status}"
      end
    end
    
    # Force clear the job queue
    def force_clear_jobs!
      # Clear the job queue using force option which will also clear any pending data and restart processes
      path = '/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue'
      payload = { "JobID" => "JID_CLEARALL_FORCE" }
      
      response = authenticated_request(
        :post, 
        path, 
        body: payload.to_json, 
        headers: { 'Content-Type' => 'application/json' }
      )
      
      if response.status.between?(200, 299)
        puts "Successfully force-cleared job queue".green
        
        # Monitor LC status until it's Ready
        puts "Waiting for LC status to be Ready..."
        
        retries = 12  # ~2 minutes with 10s sleep
        while retries > 0
          lc_response = authenticated_request(
            :post, 
            '/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.GetRemoteServicesAPIStatus',
            body: {}.to_json, 
            headers: { 'Content-Type': 'application/json' }
          )
          
          if lc_response.status.between?(200, 299)
            begin
              lc_data = JSON.parse(lc_response.body)
              status = lc_data["LCStatus"]
              
              if status == "Ready"
                puts "LC Status is Ready".green
                return true
              end
              
              puts "Current LC Status: #{status}. Waiting..."
            rescue JSON::ParserError
              puts "Failed to parse LC status response, will retry...".yellow
            end
          end
          
          retries -= 1
          sleep 10
        end
        
        puts "Warning: LC status did not reach Ready state within timeout".yellow
        return true
      else
        error_message = "Failed to force-clear job queue. Status code: #{response.status}"
        
        begin
          error_data = JSON.parse(response.body)
          error_message += ", Message: #{error_data['error']['message']}" if error_data['error'] && error_data['error']['message']
        rescue
          # Ignore JSON parsing errors
        end
        
        raise Error, error_message
      end
    end
    
    # Wait for a job to complete
    def wait_for_job(job_id)
      # Job ID can be a job ID, path, or response hash from another request
      job_path = if job_id.is_a?(Hash)
                   if job_id['headers'] && job_id['headers']['location']
                     job_id['headers']['location'].sub(/^\/redfish\/v1\//, '')
                   else
                     raise Error, "Invalid job hash, missing location header"
                   end
                 elsif job_id.to_s.start_with?('/redfish/v1/')
                   job_id.sub(/^\/redfish\/v1\//, '')
                 else
                   "Managers/iDRAC.Embedded.1/Jobs/#{job_id}"
                 end
      
      puts "Waiting for job to complete: #{job_id}".light_cyan
      
      retries = 36  # ~6 minutes with 10s sleep
      while retries > 0
        response = authenticated_request(:get, "/redfish/v1/#{job_path}")
        
        if response.status == 200
          begin
            job_data = JSON.parse(response.body)
            job_state = job_data["JobState"]
            
            case job_state
            when "Completed"
              puts "Job completed successfully".green
              return job_data
            when "Failed"
              puts "Job failed: #{job_data['Message']}".red
              raise Error, "Job failed: #{job_data['Message']}"
            when "CompletedWithErrors"
              puts "Job completed with errors: #{job_data['Message']}".yellow
              return job_data
            end
            
            puts "Job state: #{job_state}. Waiting...".yellow
          rescue JSON::ParserError
            puts "Failed to parse job status response, will retry...".yellow
          end
        else
          puts "Failed to get job status. Status code: #{response.status}".red
        end
        
        retries -= 1
        sleep 10
      end
      
      raise Error, "Timeout waiting for job to complete"
    end
    
    # Get system tasks
    def tasks
      response = authenticated_request(:get, '/redfish/v1/TaskService/Tasks')
      
      if response.status == 200
        begin
          tasks_data = JSON.parse(response.body)
          # "Tasks: #{tasks_data['Members'].count}", 0 
          return tasks_data['Members']
        rescue JSON::ParserError
          raise Error, "Failed to parse tasks response: #{response.body}"
        end
      else
        raise Error, "Failed to get tasks. Status code: #{response.status}"
      end
    end
  end
end 