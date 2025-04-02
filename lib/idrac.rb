# frozen_string_literal: true

require 'httparty'
require 'nokogiri'
require 'faraday'
require 'faraday/multipart'
require 'base64'
require 'uri'
require 'colorize'
# If dev, required debug
require 'debug' if ENV['RUBY_ENV'] == 'development'

require_relative "idrac/version"
require_relative "idrac/error"
require_relative "idrac/session"
require_relative "idrac/web"
require_relative "idrac/power"
require_relative "idrac/client"
require_relative "idrac/firmware"
require_relative "idrac/firmware_catalog"

module IDRAC
  class Error < StandardError; end
  
  def self.new(options = {})
    Client.new(options)
  end
end
