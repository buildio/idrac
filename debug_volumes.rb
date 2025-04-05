#!/usr/bin/env ruby

require_relative 'lib/idrac'

host = 'localhost'
port = 58505
username = 'root'
password = 'calvin'

puts "Debugging volumes method..."
client = IDRAC::Client.new(
  host: host,
  username: username,
  password: password,
  port: port,
  use_ssl: true,
  verify_ssl: false
)

begin
  puts "Connecting to iDRAC..."
  client.login
  
  puts "\nGetting controller info..."
  controller = client.controller
  puts "Controller: #{controller['Name']} (#{controller['Model']})"
  
  puts "\nChecking Volumes location..."
  
  # Debug the controller Volumes property
  puts "Volumes in controller: #{controller['Volumes'].inspect}"
  
  # Manually trace through volumes method
  v = controller["Volumes"]
  path = v["@odata.id"].split("v1/").last
  puts "Path: #{path}"
  
  response = client.authenticated_request(:get, "/redfish/v1/#{path}?$expand=*($levels=1)")
  puts "Response status: #{response.status}"
  
  data = JSON.parse(response.body)
  puts "Members count: #{data['Members'].size}"
  
  first_vol = data['Members'].first
  puts "First volume: #{first_vol.keys.join(', ')}"
  
  # Debug the specific place that's failing
  volumes = data["Members"].map.with_index do |vol, i|
    puts "Processing volume #{i}..."
    drives = vol["Links"]["Drives"]
    puts "  Drives count: #{drives.size}"
    
    # Build volume data incrementally with verbose output
    volume_data = {}
    puts "  Adding basic properties..."
    volume_data[:name] = vol["Name"]
    volume_data[:capacity_bytes] = vol["CapacityBytes"]
    volume_data[:volume_type] = vol["VolumeType"]
    volume_data[:drives] = drives
    volume_data[:raid_level] = vol["RAIDType"]
    volume_data[:encrypted] = vol["Encrypted"]
    volume_data[:odata_id] = vol["@odata.id"]
    
    puts "  Adding Dell properties..."
    volume_data[:write_cache_policy] = vol.dig("Oem", "Dell", "DellVirtualDisk", "WriteCachePolicy")
    volume_data[:read_cache_policy] = vol.dig("Oem", "Dell", "DellVirtualDisk", "ReadCachePolicy")
    volume_data[:stripe_size] = vol.dig("Oem", "Dell", "DellVirtualDisk", "StripeSize")
    volume_data[:lock_status] = vol.dig("Oem", "Dell", "DellVirtualDisk", "LockStatus")
    
    puts "  Volume data before fastpath: #{volume_data.inspect}"
    
    # Now create a struct with the data we have so far
    puts "  Creating RecursiveOpenStruct..."
    volume = RecursiveOpenStruct.new(volume_data, recurse_over_arrays: true)
    
    # Add operation status
    puts "  Adding operation status..."
    if vol["Operations"] && vol["Operations"].any?
      puts "    Has operations"
      volume.health = vol["Status"]["Health"] ? vol["Status"]["Health"] : "N/A"
      volume.progress = vol["Operations"].first["PercentageComplete"]
      volume.message = vol["Operations"].first["OperationName"]
    elsif vol["Status"]["Health"] == "OK"
      puts "    Status OK"
      volume.health = "OK"
    else
      puts "    Other status"
      volume.health = "?"
    end
    
    # Check FastPath settings
    puts "  Checking fastpath..."
    volume.fastpath = client.fastpath_good?(volume)
    puts "  Fastpath result: #{volume.fastpath}"
    
    puts "  Final volume attributes: #{volume.instance_variable_get(:@table).keys.join(', ')}"
    volume
  end
  
  puts "\nProcessed #{volumes.size} volumes successfully"
  
rescue => e
  puts "Error: #{e.message}"
  puts e.backtrace
ensure
  client.logout rescue nil
end 