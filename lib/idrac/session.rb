require 'faraday'
require 'base64'
require 'json'
require 'colorize'
require 'uri'

module IDRAC
  class Session
    attr_reader :host, :username, :password, :port, :use_ssl, :verify_ssl, 
                :x_auth_token, :session_location, :direct_mode, :auto_delete_sessions

    def initialize(client)
      @client = client
      @host = client.host
      @username = client.username
      @password = client.password
      @port = client.port
      @use_ssl = client.use_ssl
      @verify_ssl = client.verify_ssl
      @x_auth_token = nil
      @session_location = nil
      @direct_mode = client.direct_mode
      @sessions_maxed = false
      @auto_delete_sessions = client.auto_delete_sessions
    end

    def connection
      @connection ||= Faraday.new(url: base_url, ssl: { verify: verify_ssl }) do |faraday|
        faraday.request :multipart
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
      end
    end

    # Force clear all sessions by directly using Basic Auth
    def force_clear_sessions
      puts "Attempting to force clear all sessions...".light_cyan
      
      if delete_all_sessions_with_basic_auth
        puts "Successfully cleared sessions using Basic Auth".green
        true
      else
        puts "Failed to clear sessions using Basic Auth".red
        false
      end
    end

    # Delete all sessions using Basic Authentication
    def delete_all_sessions_with_basic_auth
      puts "Attempting to delete all sessions using Basic Authentication...".light_cyan
      
      # First, get the list of sessions
      sessions_url = '/redfish/v1/SessionService/Sessions'
      
      begin
        # Get the list of sessions
        response = request_with_basic_auth(:get, sessions_url)
        
        if response.status != 200
          puts "Failed to get sessions list: #{response.status} - #{response.body}".red
          return false
        end
        
        # Parse the response to get session IDs
        begin
          sessions_data = JSON.parse(response.body)
          
          if sessions_data['Members'] && sessions_data['Members'].any?
            puts "Found #{sessions_data['Members'].count} active sessions".light_yellow
            
            # Delete each session
            success = true
            sessions_data['Members'].each do |session|
              session_url = session['@odata.id']
              
              # Skip if no URL
              next unless session_url
              
              # Delete the session
              delete_response = request_with_basic_auth(:delete, session_url)
              
              if delete_response.status == 200 || delete_response.status == 204
                puts "Successfully deleted session: #{session_url}".green
              else
                puts "Failed to delete session #{session_url}: #{delete_response.status}".red
                success = false
              end
              
              # Small delay between deletions
              sleep(1)
            end
            
            return success
          else
            puts "No active sessions found".light_yellow
            return true
          end
        rescue JSON::ParserError => e
          puts "Error parsing sessions response: #{e.message}".red.bold
          return false
        end
      rescue => e
        puts "Error during session deletion with Basic Auth: #{e.message}".red.bold
        return false
      end
    end

    # Create a Redfish session
    def create
      # Skip if we're in direct mode
      if @direct_mode
        puts "Skipping Redfish session creation (direct mode)".light_yellow
        return false
      end
      
      url = '/redfish/v1/SessionService/Sessions'
      payload = { "UserName" => username, "Password" => password }
      
      # Try creation methods in sequence
      return true if create_session_with_content_type(url, payload)
      return true if create_session_with_basic_auth(url, payload)
      return true if handle_max_sessions_and_retry(url, payload)
      return true if create_session_with_form_urlencoded(url, payload)
      
      # If all attempts fail, switch to direct mode
      @direct_mode = true
      false
    end
    
    # Delete the Redfish session
    def delete
      return unless @x_auth_token && @session_location
      
      begin
        puts "Deleting Redfish session...".light_cyan
        
        # Use the X-Auth-Token for authentication
        headers = { 'X-Auth-Token' => @x_auth_token }
        
        response = connection.delete(@session_location) do |req|
          req.headers.merge!(headers)
        end
        
        if response.status == 200 || response.status == 204
          puts "Redfish session deleted successfully".green
          @x_auth_token = nil
          @session_location = nil
          return true
        else
          puts "Failed to delete Redfish session: #{response.status} - #{response.body}".red
          return false
        end
      rescue => e
        puts "Error during Redfish session deletion: #{e.message}".red.bold
        return false
      end
    end

    private

    def base_url
      protocol = use_ssl ? 'https' : 'http'
      "#{protocol}://#{host}:#{port}"
    end
    
    def basic_auth_headers
      {
        'Authorization' => "Basic #{Base64.strict_encode64("#{username}:#{password}")}",
        'Content-Type' => 'application/json'
      }
    end
    
    def request_with_basic_auth(method, url, body = nil)
      connection.send(method, url) do |req|
        req.headers.merge!(basic_auth_headers)
        req.body = body if body
      end
    rescue => e
      puts "Error during #{method} request with Basic Auth: #{e.message}".red.bold
      raise e
    end
    
    def process_session_response(response)
      if response.status == 201 || response.status == 200
        @x_auth_token = response.headers['X-Auth-Token']
        @session_location = response.headers['Location']
        @sessions_maxed = false
        true
      else
        false
      end
    end
    
    def create_session_with_content_type(url, payload)
      begin
        response = connection.post(url) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.body = payload.to_json
        end
        
        if process_session_response(response)
          puts "Redfish session created successfully".green
          return true
        end
      rescue => e
        puts "First session creation attempt failed: #{e.message}".light_red
      end
      false
    end
    
    def create_session_with_basic_auth(url, payload)
      begin
        response = request_with_basic_auth(:post, url, payload.to_json)
        
        if process_session_response(response)
          puts "Redfish session created successfully with Basic Auth".green
          return true
        elsif response.status == 400 && response.body.include?("maximum number of user sessions")
          puts "Maximum sessions reached during Redfish session creation".light_red
          @sessions_maxed = true
          return false
        else
          puts "Failed to create Redfish session: #{response.status} - #{response.body}".red
          return false
        end
      rescue => e
        puts "Error during Redfish session creation with Basic Auth: #{e.message}".red.bold
        return false
      end
    end
    
    def handle_max_sessions_and_retry(url, payload)
      return false unless @sessions_maxed && @auto_delete_sessions
      
      puts "Auto-delete sessions is enabled, attempting to clear sessions".light_cyan
      if force_clear_sessions
        puts "Successfully cleared sessions, trying to create a new session".green
        
        # Try one more time after clearing
        response = request_with_basic_auth(:post, url, payload.to_json)
        
        if process_session_response(response)
          puts "Redfish session created successfully after clearing sessions".green
          return true
        else
          puts "Failed to create Redfish session after clearing sessions: #{response.status} - #{response.body}".red
          return false
        end
      else
        puts "Failed to clear sessions, switching to direct mode".light_yellow
        return false
      end
    end
    
    def create_session_with_form_urlencoded(url, payload)
      # Only try with form-urlencoded if we had a 415 error previously
      begin
        puts "Trying with form-urlencoded content type".light_cyan
        response = connection.post(url) do |req|
          req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          req.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
          req.body = "UserName=#{URI.encode_www_form_component(username)}&Password=#{URI.encode_www_form_component(password)}"
        end
        
        if process_session_response(response)
          puts "Redfish session created successfully with form-urlencoded".green
          return true
        else
          puts "Failed with form-urlencoded too: #{response.status} - #{response.body}".red
          return false
        end
      rescue => e
        puts "Error during form-urlencoded session creation: #{e.message}".red.bold
        return false
      end
    end
  end
end 