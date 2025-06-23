# IDRAC

A Ruby client for the Dell iDRAC API. This gem provides a command-line interface and a Ruby API for interacting with Dell iDRAC servers.

## Features

- Take screenshots of the iDRAC console
- Update firmware using Dell's catalog
- Check for firmware updates
- Interactive firmware update process with robust error handling
- Simplified catalog download without requiring host connection
- Comprehensive error handling with clear user guidance
- Automatic job tracking and monitoring for firmware updates
- Color-coded terminal output for improved readability and user experience
- Job queue management (clear, monitor, list)
- Lifecycle log and System Event Log (SEL) management
- Lifecycle Controller status management
- Return values as RecursiveOpenStruct objects for convenient attribute access
- Reset iDRAC functionality

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'idrac'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install idrac

## Usage

### Command Line Interface

The gem provides a command-line interface for interacting with iDRAC servers:

```bash
# Take a screenshot of the iDRAC console
idrac screenshot --host=192.168.1.100
# Specify a custom output filename
idrac screenshot --host=192.168.1.100

# Download the Dell firmware catalog (no host required)
idrac catalog download
# or
idrac firmware:catalog

# Check firmware status and available updates
idrac firmware:status --host=192.168.1.100 

# Update firmware using a specific file
idrac firmware:update /path/to/firmware.exe --host=192.168.1.100 

# Interactive firmware update
idrac firmware:interactive --host=192.168.1.100 

# Display a summary of system information
idrac summary --host=192.168.1.100 
# With verbose output for debugging
idrac summary --host=192.168.1.100 

# Job Management Commands
idrac jobs:list --host=192.168.1.100 
idrac jobs:detail --host=192.168.1.100 
idrac jobs:clear --host=192.168.1.100 
idrac jobs:force_clear --host=192.168.1.100 
idrac jobs:wait JID_12345678 --host=192.168.1.100 
idrac tasks --host=192.168.1.100 

# Lifecycle Controller Commands
idrac lifecycle:status --host=192.168.1.100 
idrac lifecycle:enable --host=192.168.1.100 
idrac lifecycle:disable --host=192.168.1.100 
idrac lifecycle:ensure --host=192.168.1.100 
idrac lifecycle:clear --host=192.168.1.100 

# System Event Log (SEL) Commands
idrac sel:clear --host=192.168.1.100 

# Reset iDRAC
idrac reset --host=192.168.1.100
```

All commands automatically handle session expiration by re-authenticating when necessary, ensuring that long-running operations like firmware updates complete successfully even if the iDRAC session times out.

#### Session Management Options

By default, the client will automatically delete existing sessions when the maximum session limit is reached. You can control this behavior with the `--auto-delete-sessions` option:

```bash
# Disable automatic session deletion (use direct mode instead when max sessions reached)
idrac firmware:status --host=192.168.1.100 --no-auto-delete-sessions

# Explicitly enable automatic session deletion (this is the default)
idrac firmware:status --host=192.168.1.100 --auto-delete-sessions
```

When `--auto-delete-sessions` is enabled (the default), the client will attempt to delete existing sessions when it encounters a "maximum number of user sessions" error. When disabled, it will switch to direct mode (using Basic Authentication) instead of trying to clear sessions.

### Ruby API

```ruby
require 'idrac'

# Create a client
client = IDRAC.new(
  host: '192.168.1.100',
  username: 'root',
  password: 'calvin'
)

# The client automatically handles session expiration (401 errors)
# by re-authenticating and retrying the request

# Take a screenshot (using the client method)
filename = client.screenshot
puts "Screenshot saved to: #{filename}"

# Firmware operations
firmware = IDRAC::Firmware.new(client)

# Download catalog (no client required)
catalog = IDRAC::FirmwareCatalog.new
catalog_path = catalog.download

# Get system inventory
inventory = firmware.get_system_inventory
puts "Service Tag: #{inventory[:system][:service_tag]}"

# Check for updates
updates = firmware.check_updates(catalog_path)
updates.each do |update|
  puts "#{update[:name]}: #{update[:current_version]} -> #{update[:available_version]}"
end

# Update firmware
job_id = firmware.update('/path/to/firmware.exe', wait: true)
puts "Update completed with job ID: #{job_id}"

# Reset iDRAC
reset_successful = client.reset!
puts "iDRAC reset #{reset_successful ? 'completed successfully' : 'failed'}"

# Job management
jobs = client.jobs
puts "Found #{jobs['Members'].count} jobs"

# List job details
client.jobs_detail

# Clear all jobs
client.clear_jobs!

# Force clear job queue (use with caution)
client.force_clear_jobs!

# Wait for a specific job to complete
job_data = client.wait_for_job("JID_12345678")

# Lifecycle Controller operations
# Check if Lifecycle Controller is enabled
status = client.get_idrac_lifecycle_status

# Enable Lifecycle Controller
client.set_idrac_lifecycle_status(true)

# Ensure Lifecycle Controller is enabled
client.ensure_lifecycle_controller!

# Clear Lifecycle log
client.clear_lifecycle!

# Clear System Event Logs
client.clear_system_event_logs!

# Working with hash objects
# Methods return data as Ruby hashes with string keys for consistent access

# Working with system components
# Methods return data as Ruby hashes with string keys for consistent access

# Get memory information
memory_modules = client.memory
memory_modules.each do |dimm|
  # Access properties via string keys
  puts "#{dimm["name"]}: #{dimm["capacity_bytes"] / (1024**3)}GB, Speed: #{dimm["speed_mhz"]}MHz"
end

# Get storage information
controller = client.controller
volumes = client.volumes(controller)
volumes.each do |volume|
  # Access properties via string keys
  puts "#{volume["name"]} (#{volume["raid_level"]}): #{volume["capacity_bytes"] / (1024**3)}GB"
  puts "  Health: #{volume["health"]}, FastPath: #{volume["fastpath"]}"
end

# Create a client with auto_delete_sessions disabled
client = IDRAC.new(
  host: '192.168.1.100',
  username: 'root',
  password: 'calvin',
  auto_delete_sessions: false
)
```

### Basic Usage (Manual Session Management)

For manual control over session lifecycle:

```ruby
require 'idrac'

client = IDRAC::Client.new(
  host: "192.168.1.100",
  username: "root",
  password: "calvin"
)

# Always remember to logout to clean up sessions
begin
  client.login
  puts client.get_power_state
  puts client.system_info
ensure
  client.logout
end
```

### Block-based Usage (Recommended)

The gem provides a block-based API that automatically handles session cleanup:

```ruby
require 'idrac'

# Using IDRAC.connect - automatically handles login/logout
IDRAC.connect(host: "192.168.1.100", username: "root", password: "calvin") do |client|
  puts client.get_power_state
  puts client.system_info
  # Session is automatically cleaned up when block exits
end

# Or using Client.connect
IDRAC::Client.connect(host: "192.168.1.100", username: "root", password: "calvin") do |client|
  puts client.get_power_state
  # Session cleanup is guaranteed
end
```

### Automatic Session Cleanup

The gem now includes automatic session cleanup mechanisms:

1. **Finalizer**: Sessions are automatically cleaned up when the client object is garbage collected
2. **Block-based API**: The `connect` method ensures sessions are cleaned up even if exceptions occur
3. **Manual cleanup**: You can still call `client.logout` manually

This prevents the "RAC0218: The maximum number of user sessions is reached" error that occurred when sessions were not properly cleaned up.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Changelog

### Version 0.7.8
- **Network Redirection Support**: Added optional `host_header` parameter to Client initialization
- Enables iDRAC access through network redirection scenarios where the connection IP differs from the Host header requirement
- **Configurable VNC Port**: Made VNC port configurable in `set_idrac_ip` function with `vnc_port` parameter (default: 5901)

### Version 0.7.7
- **Bug Fix**: Fixed Session base_url method to use instance variables instead of client delegation
- Resolved "undefined local variable or method 'client'" error in session.rb

### Version 0.7.6
- **PR Preparation**: Updated version for PR submission

### Version 0.7.5
- **Code Cleanup**: Consolidated duplicate methods across the codebase
- Removed 5 sets of duplicate methods: `base_url`, `get_firmware_version`, `wait_for_task`, `handle_location`, and `extract_identifiers`
- Simplified method delegation patterns for better maintainability
- Eliminated ~150+ lines of duplicate code while preserving all functionality

### Version 0.7.4
- Added tolerance fol SSL Timeout errors during iDRAC operations.

### Version 0.7.3
- Improved error handling around SystemConfigurationProfile.

### Version 0.7.2
- **Added iDRAC Reset Functionality**: New `reset!` method to gracefully restart the iDRAC controller
- Added CLI command `idrac reset` to restart iDRAC from the command line
- Improved error handling and reconnection logic during iDRAC restart

### Version 0.1.40
- **Enhanced Return Values**: Methods that return system components now provide RecursiveOpenStruct objects
  - Memory, drives, volumes, PSUs, and fans now support convenient dot notation for attribute access
  - Improved object structure with consistent property naming across different component types
  - Better code organization and readability when working with returned objects

### Version 0.1.39
- **Added Job Management**: New methods for managing iDRAC jobs
  - List jobs using `jobs` and `jobs_detail`
  - Clear jobs with `clear_jobs!` 
  - Force clear job queue with `force_clear_jobs!`
  - Wait for specific jobs with `wait_for_job`
- **Added Lifecycle Controller Management**: New methods for managing the Lifecycle Controller
  - Check Lifecycle Controller status with `get_idrac_lifecycle_status`
  - Enable/disable Lifecycle Controller with `set_idrac_lifecycle_status`
  - Ensure Lifecycle Controller is enabled with `ensure_lifecycle_controller!`
  - Clear Lifecycle logs with `clear_lifecycle!`
  - Clear System Event Logs with `clear_system_event_logs!`
- Improved API organization with dedicated modules for related functionality

### Version 0.1.38
- **Enhanced License Display**: Updated the summary command to show both license type and description
- Improved readability by displaying license information in the format "Type (Description)"
- Better user experience with more detailed license information

### Version 0.1.37
- **Improved License Detection**: Enhanced license detection using both DMTF standard and Dell OEM methods
- Added fallback mechanisms to ensure proper license type detection
- Improved error handling for license information retrieval

### Version 0.1.36
- **Fixed License Type Display**: Updated the summary command to correctly display Enterprise license
- **Added Verbose Mode**: New `--verbose` option for the summary command to show detailed API responses
- Improved debugging capabilities with raw JSON output of system, iDRAC, network, and license information

### Version 0.1.35
- **Added System Summary Command**: New `summary` command to display key system information
- Shows power state, model, host name, OS details, service tag, firmware versions, and more
- Formatted output with color-coding for improved readability

### Version 0.1.34
- **Fixed Gem Build Process**: Corrected version mismatch in the Rakefile
- **Improved CLI Structure**: Removed hardcoded command list in favor of explicit host requirements in each command
- Enhanced code organization and maintainability

### Version 0.1.33
- **Fixed Command-Line Interface**: Improved handling of commands that don't require a host
- Made the `firmware:catalog` command work without requiring host, username, and password
- Enhanced command-line interface reliability

### Version 0.1.32
- **Fixed Gem Loading Issues**: Ensured proper loading of the colorize gem in the main module
- Resolved issues with running commands when installed as a gem
- Improved reliability of command-line interface

### Version 0.1.31
- **Enhanced Job Monitoring**: Improved firmware update job tracking and monitoring
- Added more robust error handling during firmware updates
- Enhanced progress reporting with color-coded status messages
- Improved recovery mechanisms for common firmware update issues

### Version 0.1.30
- **Added Color Output**: Enhanced terminal output with color-coded messages
- Improved readability of status, warning, and error messages
- Added the colorize gem as a dependency

### Version 0.1.29
- **Enhanced Firmware Update Error Handling**: Improved detection and handling of common firmware update issues
- Added specific error handling for "deployment already in progress" scenarios with clear user guidance
- Improved job ID extraction with fallback mechanisms to ensure proper job tracking
- Enhanced the `upload_firmware` method to properly initiate firmware updates by calling the SimpleUpdate action
- Added informative messages before starting firmware updates, including iDRAC limitations and requirements
- Simplified the catalog download process by removing host requirement from the `firmware:catalog` command
- Added a comprehensive test script (`test_firmware_update.rb`) to demonstrate the firmware update process
- Improved user experience with better error messages and recovery suggestions for common issues

### Version 0.1.28
- **Improved Firmware Update Checking**: Completely redesigned the firmware update checking process
- Added a dedicated `FirmwareCatalog` class for better separation of concerns
- Improved component matching with more accurate detection of available updates
- Enhanced output format with a tabular display showing component details, versions, and update status
- Added system model detection for more accurate firmware matching
- Improved version comparison logic for different version formats (numeric, Dell A00 format, etc.)
- Better handling of network adapters and other component types

### Version 0.1.27
- **Removed Host Requirement for Catalog Download**: The `catalog download` and `firmware:catalog` commands no longer require the `--host` parameter
- Added a dedicated `catalog` command that can be used directly: `idrac catalog download`
- The catalog download functionality can now be used without an iDRAC connection
- Updated the Ruby API to support catalog downloads without a client

### Version 0.1.26
- **Improved Redfish Session Creation**: Fixed issues with the Redfish session creation process
- Added multiple fallback methods for creating sessions with different iDRAC versions
- Fixed 415 Unsupported Media Type error by trying different content types
- Added support for form-urlencoded requests when JSON requests fail
- Enhanced error handling and logging during session creation

### Version 0.1.25
- **Enhanced Component Matching**: Improved firmware component matching with catalog entries
- Added extraction of model numbers and identifiers from component names (X520, H730, etc.)
- Implemented multiple matching strategies for better accuracy
- Added special handling for different component types (NIC, PERC, BIOS, iDRAC, etc.)
- Improved matching for components with different naming conventions

### Version 0.1.24
- **Improved Firmware Update Check**: Fixed issues with firmware version comparison
- Eliminated duplicate entries in firmware update results
- Improved matching logic between installed firmware and catalog entries
- Added proper handling of BIOS updates
- Fixed missing version information in update output
- Enhanced name comparison with case-insensitive matching

### Version 0.1.23
- **Fixed Duplicate Messages**: Removed duplicate "Retrieving system inventory..." message in firmware:status command
- The message was appearing twice because it was being printed by both the CLI class and the Firmware class
- Improved user experience by eliminating redundant output

### Version 0.1.22
- **Session Management Control**: Added `--auto-delete-sessions` CLI option (default: true)
- When enabled, the client automatically deletes existing sessions when maximum session limit is reached
- When disabled, the client switches to direct mode instead of trying to clear sessions
- Added detailed logging for session management decisions
- Updated documentation with examples of how to use the new option

### Version 0.1.21
- **Improved Authentication Flow**: Completely restructured the login process
- Renamed `
