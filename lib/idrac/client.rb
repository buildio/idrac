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
    attr_accessor :direct_mode
    
    include PowerMethods
    include SessionMethods

    def initialize(host:, username:, password:, port: 443, use_ssl: true, verify_ssl: false, direct_mode: false, auto_delete_sessions: true)
      @host = host
      @username = username
      @password = password
      @port = port
      @use_ssl = use_ssl
      @verify_ssl = verify_ssl
      @direct_mode = direct_mode
      @auto_delete_sessions = auto_delete_sessions
      
      # Initialize the session and web classes
      @session = Session.new(self)
      @web = Web.new(self)
    end

    def connection
      @connection ||= Faraday.new(url: base_url, ssl: { verify: verify_ssl }) do |faraday|
        faraday.request :multipart
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
      end
    end

    # Login to iDRAC
    def login
      # If we're in direct mode, skip login attempts
      if @direct_mode
        puts "Using direct mode (Basic Auth) for all requests".light_yellow
        return true
      end
      
      # Try to create a Redfish session
      if session.create
        puts "Successfully logged in to iDRAC using Redfish session".green
        return true
      else
        puts "Failed to create Redfish session, falling back to direct mode".light_yellow
        @direct_mode = true
        return true
      end
    end

    # Logout from iDRAC
    def logout
      session.delete if session.x_auth_token
      web.logout if web.session_id
      puts "Logged out from iDRAC".green
      return true
    end

    # Make an authenticated request to the iDRAC
    def authenticated_request(method, path, options = {}, retry_count = 0)
      # Limit retries to prevent infinite loops
      if retry_count >= 3
        puts "Maximum retry count reached for authenticated request".red.bold
        raise Error, "Maximum retry count reached for authenticated request"
      end
      
      # If we're in direct mode, use Basic Auth
      if @direct_mode
        # Create Basic Auth header
        auth_header = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
        
        # Add the Authorization header to the request
        options[:headers] ||= {}
        options[:headers]['Authorization'] = auth_header
        
        # Make the request
        begin
          response = connection.send(method, path) do |req|
            req.headers.merge!(options[:headers])
            req.body = options[:body] if options[:body]
          end
          
          return response
        rescue => e
          puts "Error during authenticated request (direct mode): #{e.message}".red.bold
          raise Error, "Error during authenticated request: #{e.message}"
        end
      else
        # Use X-Auth-Token if available
        if session.x_auth_token
          # Add the X-Auth-Token header to the request
          options[:headers] ||= {}
          options[:headers]['X-Auth-Token'] = session.x_auth_token
          
          # Make the request
          begin
            response = connection.send(method, path) do |req|
              req.headers.merge!(options[:headers])
              req.body = options[:body] if options[:body]
            end
            
            # Check if the session is still valid
            if response.status == 401 || response.status == 403
              puts "Session expired or invalid, attempting to create a new session...".light_yellow
              
              # Try to create a new session
              if session.create
                puts "Successfully created a new session, retrying request...".green
                return authenticated_request(method, path, options, retry_count + 1)
              else
                puts "Failed to create a new session, falling back to direct mode...".light_yellow
                @direct_mode = true
                return authenticated_request(method, path, options, retry_count + 1)
              end
            end
            
            return response
          rescue => e
            puts "Error during authenticated request (token mode): #{e.message}".red.bold
            
            # Try to create a new session
            if session.create
              puts "Successfully created a new session after error, retrying request...".green
              return authenticated_request(method, path, options, retry_count + 1)
            else
              puts "Failed to create a new session after error, falling back to direct mode...".light_yellow
              @direct_mode = true
              return authenticated_request(method, path, options, retry_count + 1)
            end
          end
        else
          # If we don't have a token, try to create a session
          if session.create
            puts "Successfully created a new session, making request...".green
            return authenticated_request(method, path, options, retry_count + 1)
          else
            puts "Failed to create a session, falling back to direct mode...".light_yellow
            @direct_mode = true
            return authenticated_request(method, path, options, retry_count + 1)
          end
        end
      end
    end

    def get(path:, headers: {})
      # For screenshot functionality, we need to use the WebUI cookies
      if web.cookies.nil? && path.include?('screen/screen.jpg')
        web.login unless web.session_id
      end
      
      headers_to_use = {
        "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36",
        "Accept-Encoding" => "deflate, gzip"
      }
      
      if web.cookies
        headers_to_use["Cookie"] = web.cookies
      elsif @direct_mode
        # In direct mode, use Basic Auth
        headers_to_use["Authorization"] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
      elsif session.x_auth_token
        headers_to_use["X-Auth-Token"] = session.x_auth_token
      end
      
      HTTParty.get(
        "#{base_url}/#{path}",
        headers: headers_to_use.merge(headers),
        verify: false
      )
    end

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
  end
end
