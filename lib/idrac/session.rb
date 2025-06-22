require 'faraday'
require 'base64'
require 'json'
require 'colorize'
require 'uri'
require 'logger'
require 'socket'

module IDRAC
  class Session
    attr_reader :host, :username, :password, :port, :use_ssl, :verify_ssl, 
                :x_auth_token, :session_location, :direct_mode, :auto_delete_sessions
    attr_accessor :verbosity
    
    include Debuggable

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
      @verbosity = client.respond_to?(:verbosity) ? client.verbosity : 0
    end

    def connection
      @connection ||= Faraday.new(url: base_url, ssl: { 
        verify: verify_ssl
        # Keep SSL settings minimal for cross-version compatibility
      }) do |faraday|
        faraday.request :multipart
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
        # Add request/response logging
        if @verbosity > 0
          faraday.response :logger, Logger.new(STDOUT), bodies: @verbosity >= 2 do |logger|
            logger.filter(/(Authorization: Basic )([^,\n]+)/, '\1[FILTERED]')
            logger.filter(/(Password"=>"?)([^,"]+)/, '\1[FILTERED]')
          end
        end
      end
    end

    # Force clear all sessions by directly using Basic Auth
    def force_clear_sessions
      debug "Attempting to force clear all sessions...", 1
      
      max_retries = 3
      retry_count = 0
      
      while retry_count < max_retries
        if delete_all_sessions_with_basic_auth
          debug "Successfully cleared sessions using Basic Auth", 1, :green
          return true
        else
          retry_count += 1
          if retry_count < max_retries
            # Exponential backoff
            sleep_time = 2 ** retry_count
            debug "Retrying session clear after #{sleep_time} seconds (attempt #{retry_count+1}/#{max_retries})", 1, :light_yellow
            sleep(sleep_time)
          else
            debug "Failed to clear sessions after #{max_retries} attempts", 1, :red
            return false
          end
        end
      end
      
      false
    end

    # Delete all sessions using Basic Authentication
    def delete_all_sessions_with_basic_auth
      debug "Attempting to delete all sessions using Basic Authentication...", 1
      
      # First, get the list of sessions
      sessions_url = determine_session_endpoint
      
      begin
        # Get the list of sessions
        response = request_with_basic_auth(:get, sessions_url, nil, 'application/json')
        
        if response.status != 200
          debug "Failed to get sessions list: #{response.status} - #{response.body}", 1, :red
          # If we received HTML error, assume we can't get sessions and try direct session deletion
          if response.headers['content-type']&.include?('text/html') || response.body.to_s.include?('DOCTYPE html')
            debug "Received HTML error response, trying direct session deletion", 1, :light_yellow
            return try_delete_latest_sessions
          end
          return false
        end
        
        # Parse the response to get session IDs
        begin
          sessions_data = JSON.parse(response.body)
          
          if sessions_data['Members'] && sessions_data['Members'].any?
            debug "Found #{sessions_data['Members'].count} active sessions", 1, :light_yellow
            
            # Delete each session
            success = true
            sessions_data['Members'].each do |session|
              session_url = session['@odata.id']
              
              # Skip if no URL
              next unless session_url
              
              # Delete the session
              delete_response = request_with_basic_auth(:delete, session_url, nil, 'application/json')
              
              if delete_response.status == 200 || delete_response.status == 204
                debug "Successfully deleted session: #{session_url}", 1, :green
              else
                debug "Failed to delete session #{session_url}: #{delete_response.status}", 1, :red
                success = false
              end
              
              # Small delay between deletions
              sleep(1)
            end
            
            return success
          else
            debug "No active sessions found", 1, :light_yellow
            return true
          end
        rescue JSON::ParserError => e
          debug "Error parsing sessions response: #{e.message}", 1, :red
          debug "Trying direct session deletion", 1, :light_yellow
          return try_delete_latest_sessions
        end
      rescue => e
        debug "Error during session deletion with Basic Auth: #{e.message}", 1, :red
        debug "Trying direct session deletion", 1, :light_yellow
        return try_delete_latest_sessions
      end
    end
    
    # Try to delete sessions by direct URL when we can't list sessions
    def try_delete_latest_sessions
      # Try to delete sessions by direct URL when we can't list sessions
      debug "Attempting to delete recent sessions directly...", 1
      base_url = determine_session_endpoint
      success = false
      
      # Try session IDs 1-10 (common for iDRAC)
      (1..10).each do |id|
        session_url = "#{base_url}/#{id}"
        begin
          delete_response = request_with_basic_auth(:delete, session_url, nil, 'application/json')
          
          if delete_response.status == 200 || delete_response.status == 204
            debug "Successfully deleted session: #{session_url}", 1, :green
            success = true
          else
            debug "Failed to delete session #{session_url}: #{delete_response.status}", 1, :red
          end
        rescue => e
          debug "Error deleting session #{session_url}: #{e.message}", 1, :red
        end
        
        # Small delay between deletions
        sleep(0.5)
      end
      
      return success
    end

    # Create a Redfish session
    def create
      # Skip if we're in direct mode
      if @direct_mode
        debug "Skipping Redfish session creation (direct mode)", 1, :light_yellow
        return false
      end
      
      # Determine the correct session endpoint based on Redfish version
      session_endpoint = determine_session_endpoint
      
      payload = { "UserName" => username, "Password" => password }
      
      debug "Attempting to create Redfish session at #{base_url}#{session_endpoint}", 1
      debug "SSL verification: #{verify_ssl ? 'Enabled' : 'Disabled'}", 1
      print_connection_debug_info if @verbosity >= 2
      
      # Try creation methods in sequence
      return true if create_session_with_content_type(session_endpoint, payload)
      return true if create_session_with_basic_auth(session_endpoint, payload)
      return true if handle_max_sessions_and_retry(session_endpoint, payload)
      return true if create_session_with_form_urlencoded(session_endpoint, payload)
      
      # If all attempts fail, switch to direct mode
      @direct_mode = true
      false
    end
    
    # Delete the Redfish session
    def delete
      return false unless @x_auth_token || @session_location
      
      begin
        debug "Deleting Redfish session...", 1
        
        if @session_location
          # Use the X-Auth-Token for authentication
          headers = { 'X-Auth-Token' => @x_auth_token }
          
          begin
            response = connection.delete(@session_location) do |req|
              req.headers.merge!(headers)
            end
            
            if response.status == 200 || response.status == 204
              debug "Redfish session deleted successfully", 1, :green
              @x_auth_token = nil
              @session_location = nil
              return true
            end
          rescue => session_e
            debug "Error during session deletion via location: #{session_e.message}", 1, :yellow
            # Continue to try basic auth method
          end
        end
        
        # If deleting via session location fails or there's no session location,
        # try to delete by using the basic auth method
        if @x_auth_token
          # Try to determine session ID from the X-Auth-Token or session_location
          session_id = nil
          
          # Extract session ID from location if available
          if @session_location
            if @session_location =~ /\/([^\/]+)$/
              session_id = $1
            end
          end
          
          # If we have an extracted session ID
          if session_id
            debug "Trying to delete session by ID #{session_id}", 1
            
            begin
              endpoint = determine_session_endpoint
              delete_url = "#{endpoint}/#{session_id}"
              
              delete_response = request_with_basic_auth(:delete, delete_url, nil)
              
              if delete_response.status == 200 || delete_response.status == 204
                debug "Successfully deleted session via ID", 1, :green
                @x_auth_token = nil
                @session_location = nil
                return true
              end
            rescue => id_e
              debug "Error during session deletion via ID: #{id_e.message}", 1, :yellow
            end
          end
          
          # Last resort: clear the token variable even if we couldn't properly delete it
          debug "Clearing session token internally", 1, :yellow
          @x_auth_token = nil
          @session_location = nil
        end
        
        return false
      rescue => e
        debug "Error during Redfish session deletion: #{e.message}", 1, :red
        # Clear token variable anyway
        @x_auth_token = nil
        @session_location = nil
        return false
      end
    end

    private

    def base_url
      client.base_url
    end
    
    def print_connection_debug_info
      begin
        debug "=== Connection Debug Info ===", 2, :yellow
        debug "Host: #{host}, Port: #{port}, SSL: #{use_ssl}", 2
        debug "Ruby version: #{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}", 2
        
        begin
          debug "OpenSSL version: #{OpenSSL::OPENSSL_VERSION}", 2
        rescue => e
          debug "Could not determine OpenSSL version: #{e.message}", 2
        end
        
        # Test basic TCP connection first
        begin
          socket = TCPSocket.new(host, port)
          debug "TCP connection successful", 2, :green
          socket.close
        rescue => e
          debug "TCP connection failed: #{e.class.name}: #{e.message}", 2, :red
          debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
        end
        
        # Try SSL connection if using SSL
        if use_ssl
          begin
            tcp_client = TCPSocket.new(host, port)
            ssl_context = OpenSSL::SSL::SSLContext.new
            ssl_context.verify_mode = verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
            ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, ssl_context)
            ssl_client.connect
            debug "SSL connection successful", 2, :green
            debug "SSL protocol: #{ssl_client.ssl_version}", 2
            debug "SSL cipher: #{ssl_client.cipher.join(', ')}", 2
            
            if @verbosity >= 3
              cert = ssl_client.peer_cert
              if cert
                debug "Server certificate:", 3
                debug "  Subject: #{cert.subject}", 3
                debug "  Issuer: #{cert.issuer}", 3
                debug "  Validity: #{cert.not_before} to #{cert.not_after}", 3
                debug "  Fingerprint: #{OpenSSL::Digest::SHA256.new(cert.to_der).to_s}", 3
              else
                debug "No server certificate available", 3, :yellow
              end
            end
            
            ssl_client.close
            tcp_client.close
          rescue => e
            debug "SSL connection failed: #{e.class.name}: #{e.message}", 2, :red
            debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
          end
        end
        debug "===========================", 2, :yellow
      rescue => e
        debug "Error during connection debugging: #{e.class.name}: #{e.message}", 2, :red
        debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
      end
    end
    
    def basic_auth_headers(content_type = 'application/json')
      {
        'Authorization' => "Basic #{Base64.strict_encode64("#{username}:#{password}")}",
        'Content-Type' => content_type
      }
    end
    
    def request_with_basic_auth(method, url, body = nil, content_type = 'application/json')
      debug "Basic Auth request: #{method.to_s.upcase} #{url}", 1
      debug "Request body size: #{body.to_s.size} bytes", 2 if body
      
      connection.send(method, url) do |req|
        req.headers.merge!(basic_auth_headers(content_type))
        req.body = body if body
        debug "Request headers: #{req.headers.reject { |k,v| k =~ /auth/i }.to_json}", 2
      end
    rescue Faraday::SSLError => e
      debug "SSL Error in Basic Auth request: #{e.message}", 1, :red
      debug "OpenSSL version: #{OpenSSL::OPENSSL_VERSION}", 1
      debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
      raise e
    rescue => e
      debug "Error during #{method} request with Basic Auth: #{e.class.name}: #{e.message}", 1, :red
      debug e.backtrace.join("\n"), 2 if e.backtrace && @verbosity >= 2
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
        debug "Creating session with Content-Type: application/json", 1
        
        response = connection.post(url) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Accept'] = 'application/json'
          req.body = payload.to_json
          debug "Request headers: #{req.headers.reject { |k,v| k =~ /auth/i }.to_json}", 2
          debug "Request body: #{req.body}", 2
        end
        
        debug "Response status: #{response.status}", 1
        debug "Response headers: #{response.headers.to_json}", 2
        debug "Response body: #{response.body}", 2
        
        if response.status == 405
          debug "405 Method Not Allowed: Check if the endpoint supports POST requests and verify the request format.", 1, :red
          return false
        end
        
        if process_session_response(response)
          debug "Redfish session created successfully", 1, :green
          return true
        end
        
        # If the response status is 415 (Unsupported Media Type), try with different Content-Type
        if response.status == 415 || (response.body.to_s.include?("unsupported media type"))
          debug "415 Unsupported Media Type, trying alternate content type", 1, :yellow
          
          # Try with no content-type header, just the payload
          alt_response = connection.post(url) do |req|
            # No Content-Type header
            req.headers['Accept'] = '*/*'
            req.body = payload.to_json
          end
          
          if process_session_response(alt_response)
            debug "Redfish session created successfully with alternate content type", 1, :green
            return true
          end
        end
      rescue Faraday::SSLError => e
        debug "SSL Error: #{e.message}", 1, :red
        debug "OpenSSL version: #{OpenSSL::OPENSSL_VERSION}", 1
        debug "Connection URL: #{base_url}#{url}", 1
        debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
        return false
      rescue => e
        debug "First session creation attempt failed: #{e.class.name}: #{e.message}", 1, :light_red
        debug e.backtrace.join("\n"), 2 if e.backtrace && @verbosity >= 2
      end
      false
    end
    
    def create_session_with_basic_auth(url, payload)
      begin
        debug "Creating session with Basic Auth", 1
        
        # Try first with JSON format
        response = request_with_basic_auth(:post, url, payload.to_json, 'application/json')
        
        debug "Response status: #{response.status}", 1
        debug "Response body size: #{response.body.to_s.size} bytes", 2
        
        if @verbosity >= 2 || response.status >= 400
          debug "Response body (first 500 chars): #{response.body.to_s[0..500]}", 2
        end
        
        if process_session_response(response)
          debug "Redfish session created successfully with Basic Auth (JSON)", 1, :green
          return true
        end
        
        # If that fails, try with form-urlencoded
        if response.status == 415 || (response.body.to_s.include?("unsupported media type"))
          debug "415 Unsupported Media Type with JSON, trying form-urlencoded", 1, :yellow
          
          form_data = "UserName=#{URI.encode_www_form_component(username)}&Password=#{URI.encode_www_form_component(password)}"
          form_response = request_with_basic_auth(:post, url, form_data, 'application/x-www-form-urlencoded')
          
          if process_session_response(form_response)
            debug "Redfish session created successfully with Basic Auth (form-urlencoded)", 1, :green
            return true
          elsif form_response.status == 400
            # Check for maximum sessions error
            if (form_response.body.include?("maximum number of user sessions") || 
                form_response.body.include?("RAC0218") || 
                form_response.body.include?("Internal Server Error"))
              debug "Maximum sessions reached detected during session creation", 1, :light_red
              @sessions_maxed = true
              return false
            end
          end
        elsif response.status == 400
          # Check for maximum sessions error
          if (response.body.include?("maximum number of user sessions") || 
              response.body.include?("RAC0218") || 
              response.body.include?("Internal Server Error"))
            debug "Maximum sessions reached detected during session creation", 1, :light_red
            @sessions_maxed = true
            return false
          end
        end
        
        # Try one more approach with no Content-Type header
        debug "Trying Basic Auth with no Content-Type header", 1, :yellow
        no_content_type_response = connection.post(url) do |req|
          req.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
          req.headers['Accept'] = '*/*'
          req.body = payload.to_json
        end
        
        if process_session_response(no_content_type_response)
          debug "Redfish session created successfully with Basic Auth (no content type)", 1, :green
          return true
        end
        
        debug "Failed to create Redfish session: #{response.status} - #{response.body}", 1, :red
        return false
      rescue Faraday::SSLError => e
        debug "SSL Error in Basic Auth request: #{e.message}", 1, :red
        debug "OpenSSL version: #{OpenSSL::OPENSSL_VERSION}", 1
        debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
        return false
      rescue => e
        debug "Error during Redfish session creation with Basic Auth: #{e.class.name}: #{e.message}", 1, :red
        debug e.backtrace.join("\n"), 2 if e.backtrace && @verbosity >= 2
        return false
      end
    end
    
    def handle_max_sessions_and_retry(url, payload)
      return false unless @sessions_maxed
      
      debug "Maximum sessions reached, attempting to clear sessions", 1
      if @auto_delete_sessions
        if force_clear_sessions
          debug "Successfully cleared sessions, trying to create a new session", 1, :green
          
          # Give the iDRAC a moment to process the session deletions
          sleep(3)
          
          # Try one more time after clearing with form-urlencoded
          begin
            response = connection.post(url) do |req|
              req.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
              req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
              req.body = "UserName=#{URI.encode_www_form_component(username)}&Password=#{URI.encode_www_form_component(password)}"
            end
            
            if process_session_response(response)
              debug "Redfish session created successfully after clearing sessions", 1, :green
              return true
            else
              debug "Failed to create Redfish session after clearing sessions: #{response.status} - #{response.body}", 1, :red
              # If still failing, try direct mode
              debug "Falling back to direct mode", 1, :light_yellow
              @direct_mode = true
              return false
            end
          rescue => e
            debug "Error during session creation after clearing: #{e.class.name}: #{e.message}", 1, :red
            debug "Falling back to direct mode", 1, :light_yellow
            @direct_mode = true
            return false
          end
        else
          debug "Failed to clear sessions, switching to direct mode", 1, :light_yellow
          @direct_mode = true
          return false
        end
      else
        debug "Auto delete sessions is disabled, switching to direct mode", 1, :light_yellow
        @direct_mode = true
        return false
      end
    end
    
    def create_session_with_form_urlencoded(url, payload)
      # Only try with form-urlencoded if we had a 415 error previously
      begin
        debug "Trying with form-urlencoded content type", 1
        debug "URL: #{base_url}#{url}", 1
        
        # Try first without any authorization header
        response = connection.post(url) do |req|
          req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          req.headers['Accept'] = '*/*'
          req.body = "UserName=#{URI.encode_www_form_component(username)}&Password=#{URI.encode_www_form_component(password)}"
          debug "Request headers: #{req.headers.reject { |k,v| k =~ /auth/i }.to_json}", 2
        end
        
        debug "Response status: #{response.status}", 1
        debug "Response headers: #{response.headers.to_json}", 2
        debug "Response body: #{response.body}", 3
        
        if process_session_response(response)
          debug "Redfish session created successfully with form-urlencoded", 1, :green
          return true
        end
        
        # If that fails, try with Basic Auth + form-urlencoded
        debug "Trying form-urlencoded with Basic Auth", 1
        auth_response = request_with_basic_auth(:post, url, "UserName=#{URI.encode_www_form_component(username)}&Password=#{URI.encode_www_form_component(password)}", 'application/x-www-form-urlencoded')
        
        if process_session_response(auth_response)
          debug "Redfish session created successfully with form-urlencoded + Basic Auth", 1, :green
          return true
        end
        
        # Last resort: try with both headers (some iDRAC versions need this)
        debug "Trying with both Content-Type headers", 1
        both_response = connection.post(url) do |req|
          req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          req.headers['Accept'] = 'application/json'
          req.headers['X-Requested-With'] = 'XMLHttpRequest'
          req.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
          req.body = "UserName=#{URI.encode_www_form_component(username)}&Password=#{URI.encode_www_form_component(password)}"
        end
        
        if process_session_response(both_response)
          debug "Redfish session created successfully with multiple content types", 1, :green
          return true
        else
          debug "Failed with form-urlencoded too: #{response.status} - #{response.body}", 1, :red
          return false
        end
      rescue Faraday::SSLError => e
        debug "SSL Error in form-urlencoded request: #{e.message}", 1, :red
        debug "OpenSSL version: #{OpenSSL::OPENSSL_VERSION}", 1
        debug "Connection URL: #{base_url}#{url}", 1
        debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
        return false
      rescue => e
        debug "Error during form-urlencoded session creation: #{e.class.name}: #{e.message}", 1, :red
        debug e.backtrace.join("\n"), 2 if e.backtrace && @verbosity >= 2
        return false
      end
    end

    # Determine the correct session endpoint based on Redfish version
    def determine_session_endpoint
      begin
        debug "Checking Redfish version to determine session endpoint...", 1
        
        response = connection.get('/redfish/v1') do |req|
          req.headers['Accept'] = 'application/json'
        end
        
        if response.status == 200
          begin
            data = JSON.parse(response.body)
            redfish_version = data['RedfishVersion']
            
            if redfish_version
              debug "Detected Redfish version: #{redfish_version}", 1
              
              # For version 1.17.0 and below, use the /redfish/v1/Sessions endpoint
              # For newer versions, use /redfish/v1/SessionService/Sessions
              if Gem::Version.new(redfish_version) <= Gem::Version.new('1.17.0')
                endpoint = '/redfish/v1/Sessions'
                debug "Using endpoint #{endpoint} for Redfish version #{redfish_version}", 1
                return endpoint
              else
                endpoint = '/redfish/v1/SessionService/Sessions'
                debug "Using endpoint #{endpoint} for Redfish version #{redfish_version}", 1
                return endpoint
              end
            end
          rescue JSON::ParserError => e
            debug "Error parsing Redfish version: #{e.message}", 1, :red
            debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
          rescue => e
            debug "Error determining Redfish version: #{e.message}", 1, :red
            debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
          end
        end
      rescue => e
        debug "Error checking Redfish version: #{e.message}", 1, :red
        debug e.backtrace.join("\n"), 3 if e.backtrace && @verbosity >= 3
      end
      
      # Default to /redfish/v1/Sessions if we can't determine version
      default_endpoint = '/redfish/v1/Sessions'
      debug "Defaulting to endpoint #{default_endpoint}", 1, :light_yellow
      default_endpoint
    end
  end

  # Module containing extracted session methods to be included in Client
  module SessionUtils
    def force_clear_sessions
      debug = ->(msg, level=1, color=:light_cyan) { 
        verbosity = respond_to?(:verbosity) ? verbosity : 0
        return unless verbosity >= level
        msg = msg.send(color) if color && msg.respond_to?(color)
        puts msg
      }
      
      debug.call "Attempting to force clear all sessions...", 1
      
      if delete_all_sessions_with_basic_auth
        debug.call "Successfully cleared sessions using Basic Auth", 1, :green
        true
      else
        debug.call "Failed to clear sessions using Basic Auth", 1, :red
        false
      end
    end

    # Delete all sessions using Basic Authentication
    def delete_all_sessions_with_basic_auth
      debug = ->(msg, level=1, color=:light_cyan) { 
        verbosity = respond_to?(:verbosity) ? verbosity : 0
        return unless verbosity >= level
        msg = msg.send(color) if color && msg.respond_to?(color)
        puts msg
      }
      
      debug.call "Attempting to delete all sessions using Basic Authentication...", 1
      
      # First, get the list of sessions
      sessions_url = session&.determine_session_endpoint || '/redfish/v1/Sessions'
      
      begin
        # Get the list of sessions
        response = authenticated_request(:get, sessions_url)
        
        if response.status != 200
          debug.call "Failed to get sessions list: #{response.status} - #{response.body}", 1, :red
          return false
        end
        
        # Parse the response to get session IDs
        begin
          sessions_data = JSON.parse(response.body)
          
          if sessions_data['Members'] && sessions_data['Members'].any?
            debug.call "Found #{sessions_data['Members'].count} active sessions", 1, :light_yellow
            
            # Delete each session
            success = true
            sessions_data['Members'].each do |session|
              session_url = session['@odata.id']
              
              # Skip if no URL
              next unless session_url
              
              # Delete the session
              delete_response = authenticated_request(:delete, session_url)
              
              if delete_response.status == 200 || delete_response.status == 204
                debug.call "Successfully deleted session: #{session_url}", 1, :green
              else
                debug.call "Failed to delete session #{session_url}: #{delete_response.status}", 1, :red
                success = false
              end
              
              # Small delay between deletions
              sleep(1)
            end
            
            return success
          else
            debug.call "No active sessions found", 1, :light_yellow
            return true
          end
        rescue JSON::ParserError => e
          debug.call "Error parsing sessions response: #{e.message}", 1, :red
          return false
        end
      rescue => e
        debug.call "Error during session deletion with Basic Auth: #{e.message}", 1, :red
        return false
      end
    end
  end
end 