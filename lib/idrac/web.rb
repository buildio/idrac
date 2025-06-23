require 'httparty'
require 'nokogiri'
require 'uri'
require 'colorize'

module IDRAC
  class Web
    attr_reader :client, :session_id, :cookies

    def initialize(client)
      @client = client
      @session_id = nil
      @cookies = nil
      @tried_clearing_sessions = false
    end

    # Login to the WebUI
    def login(retry_count = 0)
      # Limit retries to prevent infinite loops
      if retry_count >= 3
        puts "Maximum retry count reached for WebUI login".red
        return false
      end
      
      # Skip if we already have a session ID
      return true if @session_id
      
      begin
        puts "Logging in to WebUI...".light_cyan
        
        # Create the login URL
        login_url = "#{base_url}/data/login"
        
        # Create the login payload
        payload = {
          'user' => client.username,
          'password' => client.password
        }
        
        # Make the login request
        response = HTTParty.post(
          login_url,
          body: payload,
          verify: client.verify_ssl,
          headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
        )
        
        # Check if the login was successful
        if response.code == 200
          # Extract the session ID from the response
          if response.body.include?('ST2')
            @session_id = response.body.match(/ST2=([^;]+)/)[1]
            @cookies = response.headers['set-cookie']
            puts "WebUI login successful".green
            return response.body
          else
            puts "WebUI login failed: No session ID found in response".red
            return false
          end
        elsif response.code == 400 && response.body.include?("maximum number of user sessions")
          puts "Maximum sessions reached during WebUI login".light_red
          
          # Try to clear sessions automatically
          if !@tried_clearing_sessions
            puts "Attempting to clear sessions automatically".light_cyan
            @tried_clearing_sessions = true
            
            if client.session.force_clear_sessions
              puts "Successfully cleared sessions, trying WebUI login again".green
              return login(retry_count + 1)
            else
              puts "Failed to clear sessions for WebUI login".red
              return false
            end
          else
            puts "Already tried clearing sessions".light_yellow
            return false
          end
        else
          puts "WebUI login failed: #{response.code} - #{response.body}".red
          return false
        end
      rescue => e
        puts "Error during WebUI login: #{e.message}".red.bold
        return false
      end
    end

    # Logout from the WebUI
    def logout
      return unless @session_id
      
      begin
        puts "Logging out from WebUI...".light_cyan
        
        # Create the logout URL
        logout_url = "#{base_url}/data/logout"
        
        # Make the logout request
        response = HTTParty.get(
          logout_url,
          verify: client.verify_ssl,
          headers: { 'Cookie' => @cookies }
        )
        
        # Check if the logout was successful
        if response.code == 200
          puts "WebUI logout successful".green
          @session_id = nil
          @cookies = nil
          return true
        else
          puts "WebUI logout failed: #{response.code} - #{response.body}".red
          return false
        end
      rescue => e
        puts "Error during WebUI logout: #{e.message}".red.bold
        return false
      end
    end

    # Capture a screenshot
    def capture_screenshot
      # Login to get the forward URL and cookies
      forward_url = login
      return nil unless forward_url
      
      # Extract the key-value pairs from the forward URL (format: index?ST1=ABC,ST2=DEF)
      tokens = forward_url.split("?").last.split(",").inject({}) do |acc, kv| 
        k, v = kv.split("=")
        acc[k] = v
        acc
      end
      
      # Generate a timestamp for the request
      timestamp_ms = (Time.now.to_f * 1000).to_i
      
      # First request to trigger the screenshot capture
      path = "data?get=consolepreview[manual%20#{timestamp_ms}]"
      res = get(path: path, headers: tokens)
      raise Error, "Failed to trigger screenshot capture." unless res.code.between?(200, 299)
      
      # Wait for the screenshot to be generated
      sleep 2
      
      # Second request to get the actual screenshot image
      path = "capconsole/scapture0.png?#{timestamp_ms}"
      res = get(path: path, headers: tokens)
      raise Error, "Failed to retrieve screenshot image." unless res.code.between?(200, 299)
      
      # Save the screenshot to a file
      filename = "idrac_screenshot_#{timestamp_ms}.png"
      File.open(filename, "wb") { |f| f.write(res.body) }
      
      # Return the filename
      filename
    end

    # HTTP GET request for WebUI operations
    def get(path:, headers: {})
      headers_to_use = {
        "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36",
        "Accept-Encoding" => "deflate, gzip"
      }
      
      if @cookies
        headers_to_use["Cookie"] = @cookies
      elsif client.direct_mode
        # In direct mode, use Basic Auth
        headers_to_use["Authorization"] = "Basic #{Base64.strict_encode64("#{client.username}:#{client.password}")}"
      end
      
      HTTParty.get(
        "#{base_url}/#{path}",
        headers: headers_to_use.merge(headers),
        verify: false
      )
    end

    private

    def base_url
      client.base_url
    end
  end
end 