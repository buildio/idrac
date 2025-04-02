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
idrac screenshot --host=192.168.1.100 --username=root --password=calvin
# Specify a custom output filename
idrac screenshot --host=192.168.1.100 --username=root --password=calvin --output=my_screenshot.png

# Download the Dell firmware catalog (no host required)
idrac catalog download
# or
idrac firmware:catalog

# Check firmware status and available updates
idrac firmware:status --host=192.168.1.100 --username=root --password=calvin

# Update firmware using a specific file
idrac firmware:update /path/to/firmware.exe --host=192.168.1.100 --username=root --password=calvin

# Interactive firmware update
idrac firmware:interactive --host=192.168.1.100 --username=root --password=calvin

# Display a summary of system information
idrac summary --host=192.168.1.100 --username=root --password=calvin
# With verbose output for debugging
idrac summary --host=192.168.1.100 --username=root --password=calvin --verbose
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

# Create a client with auto_delete_sessions disabled
client = IDRAC.new(
  host: '192.168.1.100',
  username: 'root',
  password: 'calvin',
  auto_delete_sessions: false
)
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Changelog

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