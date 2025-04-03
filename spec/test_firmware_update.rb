#!/usr/bin/env ruby

require 'lib/idrac'
require 'colorize'

# Create a client
client = IDRAC::Client.new(
  host: '127.0.0.1',
  username: 'root',
  password: 'calvin',
  verify_ssl: false
)

begin
  # Login to iDRAC
  puts "Logging in to iDRAC...".light_cyan
  client.login
  puts "Logged in successfully".green
  
  # Create a firmware instance
  firmware = IDRAC::Firmware.new(client)
  
  # Get system inventory
  puts "Getting system inventory...".light_cyan
  inventory = firmware.get_system_inventory
  
  puts "System Information:".green.bold
  puts "  Model: #{inventory[:system][:model]}".light_cyan
  puts "  Manufacturer: #{inventory[:system][:manufacturer]}".light_cyan
  puts "  Service Tag: #{inventory[:system][:service_tag]}".light_cyan
  puts "  BIOS Version: #{inventory[:system][:bios_version]}".light_cyan
  
  puts "\nInstalled Firmware:".green.bold
  inventory[:firmware].each do |fw|
    puts "  #{fw[:name]}: #{fw[:version]} (#{fw[:updateable] ? 'Updateable'.light_green : 'Not Updateable'.light_red})".light_cyan
  end
  
  # Check for updates
  catalog_path = File.expand_path("~/.idrac/Catalog.xml")
  if File.exist?(catalog_path)
    puts "\nChecking for updates using catalog: #{catalog_path}".light_cyan
    updates = firmware.check_updates(catalog_path)
    
    if updates.any?
      puts "\nAvailable Updates:".green.bold
      updates.each_with_index do |update, index|
        puts "#{index + 1}. #{update[:name]}: #{update[:current_version]} -> #{update[:available_version]}".light_cyan
      end
      
      # Interactive update for the first update
      puts "\nSelected update: #{updates.first[:name]}".light_yellow
      puts "Starting interactive update for selected component...".light_cyan.bold
      
      firmware.interactive_update(catalog_path, [updates.first])
    else
      puts "No updates available for your system.".yellow
    end
  else
    puts "\nCatalog not found at #{catalog_path}. Run 'idrac firmware:catalog' to download it.".yellow
  end
  
rescue IDRAC::Error => e
  puts "Error: #{e.message}".red.bold
ensure
  # Logout
  client.logout if client
  puts "Logged out".light_cyan
end 