# frozen_string_literal: true

require 'httparty'
require 'nokogiri'
require 'faraday'
require 'faraday/multipart'
require 'base64'
require 'uri'
require 'colorize'
require 'recursive-open-struct'
# If dev, required debug
require 'debug' if ENV['RUBY_ENV'] == 'development'

module IDRAC
  # Provides debugging functionality to IDRAC classes
  module Debuggable
    # Debug output helper - only outputs if verbosity level is high enough
    def debug(message, level = 1, color = :light_cyan)
      return unless respond_to?(:verbosity) && verbosity >= level
      color_method = color.is_a?(Symbol) && String.method_defined?(color) ? color : :to_s
      puts message.send(color_method)
      
      # For highest verbosity, also print stack trace
      if respond_to?(:verbosity) && verbosity >= 3 && caller.length > 1
        puts "  Called from:".light_yellow
        caller[1..3].each do |call|
          puts "    #{call}".light_yellow
        end
      end
    end
  end

  class Error < StandardError; end
  
  def self.new(options = {})
    Client.new(options)
  end
end

require 'idrac/version'
require 'idrac/core_ext'
require 'idrac/error'
require 'idrac/web'
require 'idrac/firmware_catalog'
require 'idrac/firmware'
require 'idrac/session'
require 'idrac/power'
require 'idrac/lifecycle'
require 'idrac/jobs'
require 'idrac/storage'
require 'idrac/system'
require 'idrac/virtual_media'
require 'idrac/boot'
require 'idrac/client'
