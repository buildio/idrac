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

    it 'falls back to name matching when there is neither a componentID nor PCI IDs' do
      fw = { name: "PERC H730P Mini", component_id: "0", version: "25.5.0.0018" }
      expect(catalog.updates_for_component(updates, fw).map { |u| u[:name] })
        .to include("PERC H730P Mini Firmware")
    end
  end

  # Measured on n006 and n003 (PowerEdge R6525, systemID 08FE, iDRAC 7.10.50.10).
  #
  # The iDRAC reports componentID "0" for any firmware it did not install
  # itself, so factory-flashed hardware arrives unmatchable: on n006, 13 of the
  # 23 installed entries report "0" — both LOMs, both ConnectX-6, the PERC and
  # all 8 drives — while BIOS, iDRAC and the PSUs carry real IDs. An entry
  # *gains* its componentID once a Dell DUP is applied (n003's LOMs went from
  # "Installed-0-22.91.5" to "Installed-108255-23.61.3"), which is exactly
  # backwards from what update matching needs: the set we cannot match is
  # first-touch hardware.
  #
  # Those same entries publish their four PCI IDs under
  # Oem.Dell.DellSoftwareInventory, and the catalog publishes componentID and
  # PCIInfo as siblings on one <Device> element (3122 of 3122 PCIInfo-bearing
  # devices also carry a componentID). PCI matching is therefore not an
  # approximation of componentID matching — it reads the same Dell table by its
  # other key. Verified on n003, where both keys are now present and select the
  # identical package set.
  #
  # The packages and IDs below are copied verbatim from the Dell catalog.
  describe 'matching by PCI ID when the iDRAC reports componentID "0"' do
    let(:catalog_xml) do
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <Manifest>
          <SoftwareComponent dellVersion="A11" vendorVersion="52.30.0-6753" path="FOLDER14615957M/3/SAS-RAID_Firmware_N6C86_WN64_52.30.0-6753_A11.EXE">
            <Name><Display lang="en">PERC H755 RAID Controller firmware version 52.30.0-6753</Display></Name>
            <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
            <Category value="SAS"><Display lang="en">SAS RAID</Display></Category>
            <SupportedDevices>
              <Device componentID="108807"><PCIInfo vendorID="1000" deviceID="10E2" subVendorID="1028" subDeviceID="1AE0"/></Device>
              <Device componentID="108809"><PCIInfo vendorID="1000" deviceID="10E2" subVendorID="1028" subDeviceID="1AE2"/></Device>
            </SupportedDevices>
            <SupportedSystems><Brand><Model systemID="08FE"><Display lang="en">R6525</Display></Model></Brand></SupportedSystems>
          </SoftwareComponent>
          <SoftwareComponent dellVersion="A05" vendorVersion="52.30.0-6347" path="FOLDER13518520M/1/SAS-RAID_Firmware_1DHXW_WN64_52.30.0-6347_A05.EXE">
            <Name><Display lang="en">PERC H355 RAID Controller firmware version 52.30.0-6347</Display></Name>
            <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
            <Category value="SAS"><Display lang="en">SAS RAID</Display></Category>
            <SupportedDevices>
              <Device componentID="111321"><PCIInfo vendorID="1000" deviceID="10E6" subVendorID="1028" subDeviceID="2172"/></Device>
            </SupportedDevices>
            <SupportedSystems><Brand><Model systemID="08FE"><Display lang="en">R6525</Display></Model></Brand></SupportedSystems>
          </SoftwareComponent>
          <SoftwareComponent dellVersion="23.61.3" vendorVersion="23.61.3" path="FOLDER12345678M/1/Network_Firmware_32W7Y_WN64_23.61.3.EXE">
            <Name><Display lang="en">Broadcom NetXtreme network device firmware (Dell), 23.6</Display></Name>
            <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
            <Category value="NIC"><Display lang="en">Network</Display></Category>
            <SupportedDevices>
              <Device componentID="108255"><PCIInfo vendorID="14E4" deviceID="165F" subVendorID="1028" subDeviceID="08FF"/></Device>
            </SupportedDevices>
            <SupportedSystems><Brand><Model systemID="08FE"><Display lang="en">R6525</Display></Model></Brand></SupportedSystems>
          </SoftwareComponent>
          <SoftwareComponent dellVersion="A00" vendorVersion="25.0.4" path="FOLDER87654321M/1/Network_Firmware_I350_25.0.4_A00.EXE">
            <Name><Display lang="en">Intel NIC Family Version 25.0.0 Firmware for Intel I350 and X550 Adapters</Display></Name>
            <ComponentType value="FRMW"><Display lang="en">Firmware</Display></ComponentType>
            <Category value="NIC"><Display lang="en">Network</Display></Category>
            <SupportedDevices>
              <Device componentID="108120"><PCIInfo vendorID="8086" deviceID="1521" subVendorID="1028" subDeviceID="0757"/></Device>
            </SupportedDevices>
            <SupportedSystems><Brand><Model systemID="08FE"><Display lang="en">R6525</Display></Model></Brand></SupportedSystems>
          </SoftwareComponent>
        </Manifest>
      XML
    end

    let(:updates) { catalog.find_updates_for_system("08FE") }

    # PERC H755N Front, as the iDRAC reports it before any Dell DUP is applied.
    let(:perc) do
      { name: "PERC H755N Front", component_id: "0", version: "52.26.0-5179",
        vendor_id: "1000", device_id: "10E2", sub_vendor_id: "1028", sub_device_id: "1AE2" }
    end

    # Broadcom NetXtreme Gigabit Ethernet LOM, likewise.
    let(:broadcom) do
      { name: "Broadcom NetXtreme Gigabit Ethernet - C4:5A:B1:BF:43:59", component_id: "0",
        version: "22.91.5",
        vendor_id: "14E4", device_id: "165F", sub_vendor_id: "1028", sub_device_id: "08FF" }
    end

    it 'records the PCI IDs each package flashes' do
      h755 = updates.find { |u| u[:name].include?("H755") }
      expect(h755[:pci_ids]).to eq(["1000/10E2/1028/1AE0", "1000/10E2/1028/1AE2"])
    end

    it 'offers the H755 package to a PERC H755N, not the H355 package' do
      # Name matching reduced both to the token "PERC" and picked the H355 by
      # catalog order, which is why two identical PERCs got different packages.
      expect(catalog.updates_for_component(updates, perc).map { |u| u[:version] })
        .to eq(["52.30.0-6753"])
    end

    it 'offers a Broadcom LOM a Broadcom package, never the Intel one' do
      # The observed failure: a Broadcom device was offered "Intel NIC Family
      # Version 25.0.0 Firmware for Intel I350 and X550 Adapters".
      matches = catalog.updates_for_component(updates, broadcom)
      expect(matches.map { |u| u[:version] }).to eq(["23.61.3"])
      expect(matches.map { |u| u[:name] }.join).not_to include("Intel")
    end

    it 'matches the Redfish spelling of the IDs against the catalog spelling' do
      # Redfish writes "0x790e"; the catalog writes bare uppercase "790E".
      redfish = broadcom.merge(vendor_id: "0x14e4", device_id: "0x165f",
                               sub_vendor_id: "0x1028", sub_device_id: "0x8ff")
      expect(catalog.updates_for_component(updates, redfish))
        .to eq(catalog.updates_for_component(updates, broadcom))
    end

    it 'selects the same package the componentID selects once the iDRAC learns it' do
      # n003 ground truth: after the DUP was applied the same LOM reports
      # componentID 108255 alongside the unchanged PCI IDs. Both keys must
      # agree, or the tool would offer a different package after every update.
      by_component_id = catalog.updates_for_component(updates, broadcom.merge(component_id: "108255"))
      expect(by_component_id).to eq(catalog.updates_for_component(updates, broadcom))
    end

    it 'prefers the componentID over the PCI IDs when the iDRAC gives one' do
      fw = broadcom.merge(component_id: "111321")
      expect(catalog.updates_for_component(updates, fw).map { |u| u[:name] })
        .to eq(["PERC H355 RAID Controller firmware version 52.30.0-6347"])
    end

    it 'falls back to vendor and device when the subsystem ID is unknown' do
      # A rebadged card with the same silicon still takes the same firmware.
      fw = broadcom.merge(sub_device_id: "FFFF")
      expect(catalog.updates_for_component(updates, fw).map { |u| u[:version] }).to eq(["23.61.3"])
    end

    it 'returns nothing rather than guessing by name when no package matches' do
      # Mellanox ConnectX-6 Dx: real device, absent from this catalog. Name
      # matching would offer it something; PCI matching correctly offers
      # nothing. A matcher that returns nothing beats one that returns an
      # Intel package for a Broadcom device.
      fw = { name: "Mellanox ConnectX-6 Dx Dual Port 100 GbE QSFP56 Adapter", component_id: "0",
             version: "22.41.10.00",
             vendor_id: "15B3", device_id: "101D", sub_vendor_id: "15B3", sub_device_id: "0058" }
      expect(catalog.updates_for_component(updates, fw)).to be_empty
    end
  end

  describe '#pci_key' do
    it 'normalizes the Redfish and catalog spellings to one form' do
      expect(catalog.pci_key("0x14e4", "0x165f", "0x1028", "0x08ff")).to eq("14E4/165F/1028/08FF")
    end

    it 'pads short IDs so "0x8ff" and "08FF" compare equal' do
      expect(catalog.pci_key("14E4", "165F", "1028", "0x8ff")).to eq("14E4/165F/1028/08FF")
    end

    it 'returns nil when any ID is missing, so "no identity" is distinguishable' do
      # BIOS, iDRAC and the PSUs carry a componentID and no PCI IDs at all.
      expect(catalog.pci_key("14E4", "165F", "1028", nil)).to be_nil
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
