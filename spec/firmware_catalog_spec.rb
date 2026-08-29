require 'spec_helper'
require 'tempfile'

# Dell DUPs must be matched to installed components by componentID, not by
# display name. Name matching picks the wrong DUP (every NIC package is called
# "Ethernet"), which iDRAC then rejects on apply with RED097.
RSpec.describe IDRAC::FirmwareCatalog do
  # Two NIC packages and one PERC package, all supported on system ID 0600.
  # The two NIC packages are near-identical by name and differ only by componentID.
  let(:catalog_xml) do
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <Manifest>
        <SoftwareComponent dellVersion="A16" vendorVersion="23.61.3" path="FOLDER01/Network_Firmware_BCM5720.EXE">
          <Name><Display lang="en">Broadcom NetXtreme Gigabit Ethernet BCM5720</Display></Name>
          <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
          <Category value="NIC"><Display lang="en">Network</Display></Category>
          <SupportedDevices>
            <Device componentID="26630"><Display lang="en">BCM5720</Display></Device>
          </SupportedDevices>
          <SupportedSystems><Brand><Model systemID="0600"><Display lang="en">R630</Display></Model></Brand></SupportedSystems>
        </SoftwareComponent>
        <SoftwareComponent dellVersion="A05" vendorVersion="22.00.6" path="FOLDER02/Network_Firmware_X520.EXE">
          <Name><Display lang="en">Intel Ethernet X520 10Gb</Display></Name>
          <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
          <Category value="NIC"><Display lang="en">Network</Display></Category>
          <SupportedDevices>
            <Device componentID="19956"><Display lang="en">X520</Display></Device>
          </SupportedDevices>
          <SupportedSystems><Brand><Model systemID="0600"><Display lang="en">R630</Display></Model></Brand></SupportedSystems>
        </SoftwareComponent>
        <SoftwareComponent dellVersion="A17" vendorVersion="25.5.9.0001" path="FOLDER03/SAS-RAID_Firmware_H730P.EXE">
          <Name><Display lang="en">PERC H730P Mini Firmware</Display></Name>
          <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
          <Category value="SAS"><Display lang="en">SAS RAID</Display></Category>
          <SupportedDevices>
            <Device componentID="101560"><Display lang="en">PERC H730P Mini</Display></Device>
          </SupportedDevices>
          <SupportedSystems><Brand><Model systemID="0600"><Display lang="en">R630</Display></Model></Brand></SupportedSystems>
        </SoftwareComponent>
      </Manifest>
    XML
  end

  let(:catalog_file) do
    file = Tempfile.new(['Catalog', '.xml'])
    file.write(catalog_xml)
    file.close
    file
  end

  let(:catalog) { described_class.new(catalog_file.path) }
  let(:updates) { catalog.find_updates_for_system("0600") }

  after { catalog_file.unlink }

  describe '#find_updates_for_system' do
    it 'records the componentIDs each package flashes' do
      perc = updates.find { |u| u[:name].include?("PERC") }
      expect(perc[:component_ids]).to eq(["101560"])
    end

    it 'uses the numeric vendorVersion, not the dellVersion revision label' do
      perc = updates.find { |u| u[:name].include?("PERC") }
      expect(perc[:version]).to eq("25.5.9.0001")
    end
  end

  describe '#updates_for_component' do
    it 'matches a package by componentID' do
      fw = { name: "PERC H730P Mini", component_id: "101560", version: "25.5.0.0018" }
      expect(catalog.updates_for_component(updates, fw).map { |u| u[:name] })
        .to eq(["PERC H730P Mini Firmware"])
    end

    it 'does not return the wrong NIC package for a same-named component' do
      # Both NIC packages say "Ethernet"; only the BCM5720 componentID applies.
      fw = { name: "NIC in Embedded 1 Port 1", component_id: "26630", version: "21.81.3" }
      matches = catalog.updates_for_component(updates, fw)
      expect(matches.map { |u| u[:component_ids] }).to eq([["26630"]])
    end

    it 'returns nothing when no package flashes that componentID' do
      fw = { name: "System CPLD", component_id: "99999", version: "1.0.0" }
      expect(catalog.updates_for_component(updates, fw)).to be_empty
    end

    it 'falls back to name matching when the inventory has no componentID' do
      fw = { name: "PERC H730P Mini", component_id: nil, version: "25.5.0.0018" }
      expect(catalog.updates_for_component(updates, fw).map { |u| u[:name] })
        .to include("PERC H730P Mini Firmware")
    end

    it 'falls back to name matching when the componentID is reported as "0"' do
      fw = { name: "PERC H730P Mini", component_id: "0", version: "25.5.0.0018" }
      expect(catalog.updates_for_component(updates, fw).map { |u| u[:name] })
        .to include("PERC H730P Mini Firmware")
    end
  end

  describe '#version_key' do
    it 'orders Dell numeric versions' do
      expect(catalog.version_key("25.5.9.0001")).to be > catalog.version_key("25.5.0.0018")
    end

    it 'picks the newest of several revisions of one package' do
      versions = ["21.81.3", "23.61.3", "22.00.6"]
      expect(versions.max_by { |v| catalog.version_key(v) }).to eq("23.61.3")
    end

    it 'sorts a version with no digits lowest instead of raising' do
      expect(catalog.version_key("N/A")).to eq(Gem::Version.new("0"))
    end
  end
end
