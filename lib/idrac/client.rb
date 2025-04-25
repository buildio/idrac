require 'faraday'
require 'faraday/multipart'
require 'nokogiri'
require 'base64'
require 'uri'
require 'httparty'
require 'json'
require 'colorize'

module IDRAC
  class Client
    attr_reader :host, :username, :password, :port, :use_ssl, :verify_ssl, :auto_delete_sessions, :session, :web
    attr_accessor :direct_mode, :verbosity, :retry_count, :retry_delay
    
    include Power
    include SessionUtils
    include Debuggable
    include Jobs
    include Lifecycle
    include Storage
    include System
    include VirtualMedia
    include Boot
    include License
    include SystemConfig

    def initialize(host:, username:, password:, port: 443, use_ssl: true, verify_ssl: false, direct_mode: false, auto_delete_sessions: true, retry_count: 3, retry_delay: 1)
      @host = host
      @username = username
      @password = password
      @port = port
      @use_ssl = use_ssl
      @verify_ssl = verify_ssl
      @direct_mode = direct_mode
      @auto_delete_sessions = auto_delete_sessions
      @verbosity = 0
      @retry_count = retry_count
      @retry_delay = retry_delay
      
      # Initialize the session and web classes
      @session = Session.new(self)
      @web = Web.new(self)
    end

    def connection
      @connection ||= Faraday.new(url: base_url, ssl: { verify: verify_ssl }) do |faraday|
        faraday.request :multipart
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
        # Add request/response logging based on verbosity
        if @verbosity > 0
          faraday.response :logger, Logger.new(STDOUT), bodies: @verbosity >= 2 do |logger|
            logger.filter(/(Authorization: Basic )([^,\n]+)/, '\1[FILTERED]')
            logger.filter(/(Password"=>"?)([^,"]+)/, '\1[FILTERED]')
          end
        end
      end
    end

    # Login to iDRAC
    def login
      # If we're in direct mode, skip login attempts
      if @direct_mode
        debug "Using direct mode (Basic Auth) for all requests", 1, :light_yellow
        return true
      end
      
      # Try to create a Redfish session
      if session.create
        debug "Successfully logged in to iDRAC using Redfish session", 1, :green
        return true
      else
        debug "Failed to create Redfish session, falling back to direct mode", 1, :light_yellow
        @direct_mode = true
        return true
      end
    end

    # Logout from iDRAC
    def logout
      session.delete if session.x_auth_token
      web.logout if web.session_id
      debug "Logged out from iDRAC", 1, :green
      return true
    end

    # Send an authenticated request to the iDRAC
    def authenticated_request(method, path, options = {})
      with_retries do
        _perform_authenticated_request(method, path, options)
      end
    end

    def get(path:, headers: {})
      with_retries do
        _perform_get(path: path, headers: headers)
      end
    end

    private
    
    # Implementation of authenticated request without retry logic
    def _perform_authenticated_request(method, path, options = {}, retry_count = 0)
      # Check retry count to prevent infinite recursion
      if retry_count >= @retry_count
        debug "Maximum retry count reached", 1, :red
        raise Error, "Failed to authenticate after #{@retry_count} retries"
      end
      
      # Form the full URL
      full_url = "#{base_url}/redfish/v1".chomp('/') + '/' + path.sub(/^\//, '')
      
      # Log the request
      debug "Authenticated request: #{method.to_s.upcase} #{path}", 1
      
      # Extract options
      body = options[:body]
      headers = options[:headers] || {}
      
      # Add client headers
      headers['User-Agent'] ||= 'iDRAC Ruby Client'
      headers['Accept'] ||= 'application/json'
      
      # If we're in direct mode, use Basic Auth
      if @direct_mode
        # Create Basic Auth header
        auth_header = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
        headers['Authorization'] = auth_header
        debug "Using Basic Auth for request (direct mode)", 2
        
        begin
          # Make the request directly
          response = session.connection.run_request(
            method,
            path.sub(/^\//, ''),
            body,
            headers
          )
          
          debug "Response status: #{response.status}", 2
          
          # Even in direct mode, check for authentication issues
          if response.status == 401 || response.status == 403
            debug "Authentication failed in direct mode, retrying with new credentials...", 1, :light_yellow
            sleep(retry_count + 1) # Add some delay before retry
            return _perform_authenticated_request(method, path, options, retry_count + 1)
          end
          
          return response
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
          debug "Connection error in direct mode: #{e.message}", 1, :red
          sleep(retry_count + 1) # Add some delay before retry
          return _perform_authenticated_request(method, path, options, retry_count + 1)
        rescue => e
          debug "Error during direct mode request: #{e.message}", 1, :red
          raise Error, "Error during authenticated request: #{e.message}"
        end
      # Use Redfish session token if available
      elsif session.x_auth_token
        begin
          headers['X-Auth-Token'] = session.x_auth_token
          
          debug "Using X-Auth-Token for authentication", 2
          debug "Request headers: #{headers.reject { |k,v| k =~ /auth/i }.to_json}", 3
          debug "Request body: #{body.to_s[0..500]}", 3 if body
          
          response = session.connection.run_request(
            method,
            path.sub(/^\//, ''),
            body,
            headers
          )
          
          debug "Response status: #{response.status}", 2
          debug "Response headers: #{response.headers.to_json}", 3
          debug "Response body: #{response.body.to_s[0..500]}", 3 if response.body
          
          # Handle session expiration
          if response.status == 401 || response.status == 403
            debug "Session expired or invalid, creating a new session...", 1, :light_yellow
            
            # If session.delete returns true, the session was successfully deleted
            if session.delete
              debug "Successfully cleared expired session", 1, :green
            end
            
            # Try to create a new session
            if session.create
              debug "Successfully created a new session after expiration, retrying request...", 1, :green
              return _perform_authenticated_request(method, path, options, retry_count + 1)
            else
              debug "Failed to create a new session after expiration, falling back to direct mode...", 1, :light_yellow
              @direct_mode = true
              return _perform_authenticated_request(method, path, options, retry_count + 1)
            end
          end
          
          return response
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
          debug "Connection error: #{e.message}", 1, :red
          sleep(retry_count + 1) # Add some delay before retry
          
          # If we still have the token, try to reuse it
          if session.x_auth_token
            debug "Retrying with existing token after connection error", 1, :light_yellow
            return _perform_authenticated_request(method, path, options, retry_count + 1)
          else
            # Otherwise try to create a new session
            debug "Trying to create a new session after connection error", 1, :light_yellow
            if session.create
              debug "Successfully created a new session after connection error", 1, :green
              return _perform_authenticated_request(method, path, options, retry_count + 1)
            else
              debug "Failed to create session after connection error, falling back to direct mode", 1, :light_yellow
              @direct_mode = true
              return _perform_authenticated_request(method, path, options, retry_count + 1)
            end
          end
        rescue => e
          debug "Error during authenticated request (token mode): #{e.message}", 1, :red
          
          # Try to create a new session
          if session.create
            debug "Successfully created a new session after error, retrying request...", 1, :green
            return _perform_authenticated_request(method, path, options, retry_count + 1)
          else
            debug "Failed to create a new session after error, falling back to direct mode...", 1, :light_yellow
            @direct_mode = true
            return _perform_authenticated_request(method, path, options, retry_count + 1)
          end
        end
      else
        # If we don't have a token, try to create a session
        if session.create
          debug "Successfully created a new session, making request...", 1, :green
          return _perform_authenticated_request(method, path, options, retry_count + 1)
        else
          debug "Failed to create a session, falling back to direct mode...", 1, :light_yellow
          @direct_mode = true
          return _perform_authenticated_request(method, path, options, retry_count + 1)
        end
      end
    end

    def _perform_get(path:, headers: {})
      # For screenshot functionality, we need to use the WebUI cookies
      if web.cookies.nil? && path.include?('screen/screen.jpg')
        web.login unless web.session_id
      end
      
      debug "GET request to #{base_url}/#{path}", 1
      
      headers_to_use = {
        "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36",
        "Accept-Encoding" => "deflate, gzip"
      }
      
      if web.cookies
        headers_to_use["Cookie"] = web.cookies
        debug "Using WebUI cookies for request", 2
      elsif @direct_mode
        # In direct mode, use Basic Auth
        headers_to_use["Authorization"] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
        debug "Using Basic Auth for GET request", 2
      elsif session.x_auth_token
        headers_to_use["X-Auth-Token"] = session.x_auth_token
        debug "Using X-Auth-Token for GET request", 2
      end
      
      debug "Request headers: #{headers_to_use.merge(headers).inspect}", 3
      
      response = HTTParty.get(
        "#{base_url}/#{path}",
        headers: headers_to_use.merge(headers),
        verify: false
      )
      
      debug "Response status: #{response.code}", 1
      debug "Response headers: #{response.headers.inspect}", 2
      debug "Response body: #{response.body.to_s[0..500]}#{response.body.to_s.length > 500 ? '...' : ''}", 3 if response.body
      
      response
    end

    public

    def screenshot
      web.capture_screenshot
    end

    def base_url
      protocol = use_ssl ? 'https' : 'http'
      "#{protocol}://#{host}:#{port}"
    end

    def redfish_version
      response = authenticated_request(:get, "/redfish/v1")
      if response.status == 200
        data = JSON.parse(response.body)
        data["RedfishVersion"]
      else
        raise Error, "Failed to get Redfish version: #{response.status} - #{response.body}"
      end
    end

    def get_firmware_version
      response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1?$select=FirmwareVersion")
      
      if response.status == 200
        begin
          data = JSON.parse(response.body)
          return data["FirmwareVersion"]
        rescue JSON::ParserError
          raise Error, "Failed to parse firmware version response: #{response.body}"
        end
      else
        # Try again without the $select parameter for older firmware
        response = authenticated_request(:get, "/redfish/v1/Managers/iDRAC.Embedded.1")
        
        if response.status == 200
          begin
            data = JSON.parse(response.body)
            return data["FirmwareVersion"]
          rescue JSON::ParserError
            raise Error, "Failed to parse firmware version response: #{response.body}"
          end
        else
          raise Error, "Failed to get firmware version. Status code: #{response.status}"
        end
      end
    end

    # Execute a block with automatic retries
    # @param max_retries [Integer] Maximum number of retry attempts
    # @param initial_delay [Integer] Initial delay in seconds between retries (increases exponentially)
    # @param error_classes [Array] Array of error classes to catch and retry
    # @yield The block to execute with retries
    # @return [Object] The result of the block
    def with_retries(max_retries = nil, initial_delay = nil, error_classes = nil)
      # Use instance variables if not specified
      max_retries ||= @retry_count
      initial_delay ||= @retry_delay
      error_classes ||= [StandardError]
      
      retries = 0
      begin
        yield
      rescue *error_classes => e
        retries += 1
        if retries <= max_retries
          delay = initial_delay * (retries ** 1.5).to_i  # Exponential backoff
          debug "RETRY: #{e.message} - Attempt #{retries}/#{max_retries}, waiting #{delay}s", 1, :yellow
          sleep delay
          retry
        else
          debug "MAX RETRIES REACHED: #{e.message} after #{max_retries} attempts", 1, :red
          raise e
        end
      end
    end
  end
end
