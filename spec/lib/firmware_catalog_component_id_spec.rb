require 'spec_helper'
require 'idrac'
require 'tempfile'

# The catalog must match an installed component to a Dell Update Package by
# *componentID*, not by display name. Names are ambiguous — every NIC DUP says
# "Ethernet" — so name-matching picks the wrong DUP, which iDRAC then rejects
# (RED097 "component not in inventory" / "DUP not compatible with the target").
RSpec.describe IDRAC::FirmwareCatalog, 'componentID matching' do
  # Two PERC DUPs (same componentID, different revisions) and two NICs that
  # share the SAME display name but have DIFFERENT componentIDs.
  let(:catalog_xml) do
    <<~XML
      <Manifest>
        <SoftwareComponent dellVersion="A16" path="FOLDER_A/WRF3Y_25.5.8.EXE">
          <Name><Display lang="en">PERC H730P Mini Controller firmware</Display></Name>
          <ComponentType><Display lang="en">Firmware</Display></ComponentType>
          <Category><Display lang="en">SAS RAID</Display></Category>
          <SupportedSystems><Brand><Model systemID="0601"/></Brand></SupportedSystems>
          <SupportedDevices><Device componentID="101560"/></SupportedDevices>
        </SoftwareComponent>
        <SoftwareComponent dellVersion="A17" path="FOLDER_B/700GG_25.5.9.EXE">
          <Name><Display lang="en">PERC H730P Mini Controller firmware</Display></Name>
          <ComponentType><Display lang="en">Firmware</Display></ComponentType>
          <Category><Display lang="en">SAS RAID</Display></Category>
          <SupportedSystems><Brand><Model systemID="0601"/></Brand></SupportedSystems>
          <SupportedDevices><Device componentID="101560"/></SupportedDevices>
        </SoftwareComponent>
        <SoftwareComponent vendorVersion="22.00.6" path="FOLDER_C/DFF48_22.00.6.EXE">
          <Name><Display lang="en">Broadcom Gigabit Ethernet</Display></Name>
          <ComponentType><Display lang="en">Firmware</Display></ComponentType>
          <Category><Display lang="en">Network</Display></Category>
          <SupportedSystems><Brand><Model systemID="0601"/></Brand></SupportedSystems>
          <SupportedDevices><Device componentID="27474"/></SupportedDevices>
        </SoftwareComponent>
        <SoftwareComponent vendorVersion="23.61.3" path="FOLDER_D/32W7Y_23.61.3.EXE">
          <Name><Display lang="en">Broadcom Gigabit Ethernet</Display></Name>
          <ComponentType><Display lang="en">Firmware</Display></ComponentType>
          <Category><Display lang="en">Network</Display></Category>
          <SupportedSystems><Brand><Model systemID="0601"/></Brand></SupportedSystems>
          <SupportedDevices><Device componentID="99999"/></SupportedDevices>
        </SoftwareComponent>
      </Manifest>
    XML
  end

  let(:catalog_file) do
    f = Tempfile.new(['catalog', '.xml'])
    f.write(catalog_xml)
    f.flush
    f
  end

  let(:catalog) { described_class.new(catalog_file.path) }
  let(:updates) { catalog.find_updates_for_system('0601') }

  after { catalog_file.close! }

  it 'captures the supported componentIDs for each DUP' do
    expect(updates.size).to eq(4)
    expect(updates).to all(satisfy { |u| u[:component_ids].is_a?(Array) && !u[:component_ids].empty? })
    nic = updates.find { |u| u[:path].include?('DFF48') }
    expect(nic[:component_ids]).to eq(['27474'])
  end

  it 'matches an installed component to DUPs by componentID, ignoring same-named ones' do
    fw = { name: 'Broadcom Gigabit Ethernet BCM5720 - B0:26:28:B3:4A:10', component_id: '27474', version: '21.81.3' }
    matched = catalog.updates_for_component(updates, fw)
    # Only the componentID-27474 DUP — NOT the identically-named 99999 NIC.
    expect(matched.map { |u| u[:path] }).to eq(['FOLDER_C/DFF48_22.00.6.EXE'])
  end

  it 'picks the newest revision among several DUPs for one componentID' do
    fw = { name: 'PERC H730P Mini', component_id: '101560', version: '25.5.8.0001' }
    matched = catalog.updates_for_component(updates, fw)
    expect(matched.size).to eq(2)
    newest = matched.max_by { |u| catalog.version_key(u[:version]) }
    expect(newest[:path]).to include('700GG') # A17 > A16
  end

  it 'falls back to name matching only when the inventory has no componentID' do
    fw = { name: 'Broadcom Gigabit Ethernet', component_id: '0', version: '21.81.3' }
    matched = catalog.updates_for_component(updates, fw)
    # Without a usable componentID, name matching returns both same-named NICs.
    expect(matched.size).to eq(2)
  end

  it 'version_key sorts Dell version strings and never raises on odd input' do
    expect(catalog.version_key('25.5.9.0001')).to be > catalog.version_key('25.5.8.0001')
    expect(catalog.version_key('22.00.6')).to be > catalog.version_key('21.81.3')
    expect { catalog.version_key(nil) }.not_to raise_error
  end
end
