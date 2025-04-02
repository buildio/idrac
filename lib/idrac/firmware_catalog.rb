require 'net/http'
require 'uri'
require 'fileutils'
require 'nokogiri'
require 'open-uri'
require 'colorize'

module IDRAC
  class FirmwareCatalog
    DELL_CATALOG_BASE = 'https://downloads.dell.com'
    DELL_CATALOG_URL = "#{DELL_CATALOG_BASE}/catalog/Catalog.xml.gz"
    
    attr_reader :catalog_path
    
    def initialize(catalog_path = nil)
      @catalog_path = catalog_path
    end
    
    def download(output_dir = nil)
      # Default to ~/.idrac directory
      output_dir ||= File.expand_path('~/.idrac')
      FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)
      
      catalog_gz = File.join(output_dir, 'Catalog.xml.gz')
      catalog_xml = File.join(output_dir, 'Catalog.xml')
      
      puts "Downloading Dell catalog from #{DELL_CATALOG_URL}...".light_cyan
      
      begin
        # Download the catalog
        URI.open(DELL_CATALOG_URL) do |remote_file|
          File.open(catalog_gz, 'wb') do |local_file|
            local_file.write(remote_file.read)
          end
        end
        
        puts "Extracting catalog...".light_cyan
        
        # Extract the catalog
        system("gunzip -f #{catalog_gz}")
        
        if File.exist?(catalog_xml)
          puts "Catalog downloaded and extracted to #{catalog_xml}".green
          @catalog_path = catalog_xml
          return catalog_xml
        else
          raise Error, "Failed to extract catalog"
        end
      rescue => e
        puts "Error downloading catalog: #{e.message}".red.bold
        raise Error, "Failed to download Dell catalog: #{e.message}"
      end
    end
    
    def parse
      raise Error, "No catalog path specified" unless @catalog_path
      raise Error, "Catalog file not found: #{@catalog_path}" unless File.exist?(@catalog_path)
      
      File.open(@catalog_path) { |f| Nokogiri::XML(f) }
    end
    
    def find_system_models(model_name)
      doc = parse
      models = []
      
      # Extract model code from full model name (e.g., "PowerEdge R640" -> "R640")
      model_code = nil
      if model_name.include?("PowerEdge")
        model_code = model_name.split.last
      else
        model_code = model_name
      end
      
      puts "Searching for model: #{model_name} (code: #{model_code})"
      
      # Build a mapping of model names to system IDs
      model_to_system_id = {}
      
      doc.xpath('//SupportedSystems/Brand/Model').each do |model|
        system_id = model['systemID'] || model['id']
        name = model.at_xpath('Display')&.text
        code = model.at_xpath('Code')&.text
        
        if name && system_id
          model_to_system_id[name] = {
            name: name,
            code: code,
            id: system_id
          }
          
          # Also map just the model number (R640, etc.)
          if name =~ /[RT]\d+/
            model_short = name.match(/([RT]\d+\w*)/)[1]
            model_to_system_id[model_short] = {
              name: name,
              code: code,
              id: system_id
            }
          end
        end
      end
      
      # Try exact match first
      if model_to_system_id[model_name]
        models << model_to_system_id[model_name]
      end
      
      # Try model code match
      if model_to_system_id[model_code]
        models << model_to_system_id[model_code]
      end
      
      # If we still don't have a match, try a more flexible approach
      if models.empty?
        model_to_system_id.each do |name, model_info|
          if name.include?(model_code) || model_code.include?(name)
            models << model_info
          end
        end
      end
      
      # If still no match, try matching by systemID directly
      if models.empty?
        doc.xpath('//SupportedSystems/Brand/Model').each do |model|
          system_id = model['systemID'] || model['id']
          name = model.at_xpath('Display')&.text
          code = model.at_xpath('Code')&.text
          
          if code && code.downcase == model_code.downcase
            models << {
              name: name,
              code: code,
              id: system_id
            }
          end
        end
      end
      
      models.uniq { |m| m[:id] }
    end
    
    def find_updates_for_system(system_id)
      doc = parse
      updates = []
      
      # Find all SoftwareComponents
      doc.xpath("//SoftwareComponent").each do |component|
        # Check if this component supports our system ID
        supported_system_ids = component.xpath(".//SupportedSystems/Brand/Model/@systemID | .//SupportedSystems/Brand/Model/@id").map(&:value)
        
        next unless supported_system_ids.include?(system_id)
        
        # Get component details
        name_node = component.xpath("./Name/Display[@lang='en']").first
        name = name_node ? name_node.text.strip : ""
        
        component_type_node = component.xpath("./ComponentType/Display[@lang='en']").first
        component_type = component_type_node ? component_type_node.text.strip : ""
        
        path = component['path'] || ""
        category_node = component.xpath("./Category/Display[@lang='en']").first
        category = category_node ? category_node.text.strip : ""
        
        version = component['dellVersion'] || component['vendorVersion'] || ""
        
        # Skip if missing essential information
        next if name.empty? || path.empty? || version.empty?
        
        # Only include firmware updates
        if component_type.include?("Firmware") ||
           category.include?("BIOS") ||
           category.include?("Firmware") ||
           category.include?("iDRAC") ||
           name.include?("BIOS") ||
           name.include?("Firmware") ||
           name.include?("iDRAC")
          
          updates << {
            name: name,
            version: version,
            path: path,
            component_type: component_type,
            category: category,
            download_url: "https://downloads.dell.com/#{path}"
          }
        end
      end
      
      puts "Found #{updates.size} firmware updates for system ID #{system_id}"
      updates
    end
    
    def extract_identifiers(name)
      return [] unless name
      
      identifiers = []
      
      # Extract model numbers like X520, I350, etc.
      model_matches = name.scan(/[IX]\d{3,4}/)
      identifiers.concat(model_matches)
      
      # Extract PERC model like H730
      perc_matches = name.scan(/[HP]\d{3,4}/)
      identifiers.concat(perc_matches)
      
      # Extract other common identifiers
      if name.include?("NIC") || name.include?("Ethernet") || name.include?("Network")
        identifiers << "NIC"
      end
      
      if name.include?("PERC") || name.include?("RAID")
        identifiers << "PERC"
        # Extract PERC model like H730
        perc_match = name.match(/PERC\s+([A-Z]\d{3})/)
        identifiers << perc_match[1] if perc_match
      end
      
      if name.include?("BIOS")
        identifiers << "BIOS"
      end
      
      if name.include?("iDRAC") || name.include?("IDRAC") || name.include?("Remote Access Controller")
        identifiers << "iDRAC"
      end
      
      if name.include?("Power Supply") || name.include?("PSU")
        identifiers << "PSU"
      end
      
      if name.include?("Lifecycle Controller")
        identifiers << "LC"
      end
      
      if name.include?("CPLD")
        identifiers << "CPLD"
      end
      
      identifiers
    end
    
    def match_component(firmware_name, catalog_name)
      # Normalize names for comparison
      catalog_name_lower = catalog_name.downcase.strip
      firmware_name_lower = firmware_name.downcase.strip
      
      # 1. Direct substring match
      return true if catalog_name_lower.include?(firmware_name_lower) || firmware_name_lower.include?(catalog_name_lower)
      
      # 2. Special case for BIOS
      return true if catalog_name_lower.include?("bios") && firmware_name_lower.include?("bios")
      
      # 3. Check identifiers
      firmware_identifiers = extract_identifiers(firmware_name)
      catalog_identifiers = extract_identifiers(catalog_name)
      
      return true if (firmware_identifiers & catalog_identifiers).any?
      
      # 4. Special case for network adapters
      if (firmware_name_lower.include?("ethernet") || firmware_name_lower.include?("network")) &&
         (catalog_name_lower.include?("ethernet") || catalog_name_lower.include?("network"))
        return true
      end
      
      # No match found
      false
    end
    
    def compare_versions(current_version, available_version)
      # If versions are identical, no update needed
      return false if current_version == available_version
      
      # If either version is N/A, no update available
      return false if current_version == "N/A" || available_version == "N/A"
      
      # Try to handle Dell's version format (e.g., A00, A01, etc.)
      if available_version.match?(/^[A-Z]\d+$/)
        # If current version doesn't match Dell's format, assume update is needed
        return true unless current_version.match?(/^[A-Z]\d+$/)
        
        # Compare Dell version format (A00 < A01 < A02 < ... < B00 < B01 ...)
        available_letter = available_version[0]
        available_number = available_version[1..-1].to_i
        
        current_letter = current_version[0]
        current_number = current_version[1..-1].to_i
        
        return true if current_letter < available_letter
        return true if current_letter == available_letter && current_number < available_number
        return false
      end
      
      # For numeric versions, try to compare them
      if current_version.match?(/^[\d\.]+$/) && available_version.match?(/^[\d\.]+$/)
        current_parts = current_version.split('.').map(&:to_i)
        available_parts = available_version.split('.').map(&:to_i)
        
        # Compare each part of the version
        max_length = [current_parts.length, available_parts.length].max
        max_length.times do |i|
          current_part = current_parts[i] || 0
          available_part = available_parts[i] || 0
          
          return true if current_part < available_part
          return false if current_part > available_part
        end
        
        # If we get here, versions are equal
        return false
      end
      
      # If we can't determine, assume update is needed
      true
    end
  end
end 