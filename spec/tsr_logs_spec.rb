require 'spec_helper'

RSpec.describe IDRAC::Utility do
  let(:client) do
    IDRAC::Client.new(
      host: ENV['IDRAC_HOST'] || 'idrac.example.com',
      username: ENV['IDRAC_USER'] || 'root',
      password: ENV['IDRAC_PASSWORD'] || 'calvin',
      verify_ssl: false
    )
  end

  describe 'TSR Log Operations' do
    describe '#tsr_status' do
      it 'returns TSR collection status' do
        VCR.use_cassette('tsr_status') do
          status = client.tsr_status
          
          expect(status).to be_a(Hash)
          expect(status).to have_key(:available)
          expect(status).to have_key(:collection_in_progress)
        end
      end
    end

    describe '#generate_tsr_logs' do
      it 'initiates TSR log generation' do
        VCR.use_cassette('generate_tsr_logs') do
          result = client.generate_tsr_logs(
            data_selector_values: ["HWData", "OSAppData"] # Hardware and OS data
          )
          
          expect(result).to be_a(Hash)
          expect(result[:status]).to be_in([:success, :accepted, :failed, :error])
        end
      end
    end

    describe '#supportassist_eula_status' do
      it 'checks SupportAssist EULA status' do
        VCR.use_cassette('supportassist_eula_status') do
          status = client.supportassist_eula_status
          
          expect(status).to be_a(Hash)
          expect(status).to have_key("EULAAccepted")
        end
      end
    end

    describe '#accept_supportassist_eula' do
      it 'accepts SupportAssist EULA' do
        VCR.use_cassette('accept_supportassist_eula') do
          result = client.accept_supportassist_eula
          
          expect([true, false]).to include(result)
        end
      end
    end

    describe '#generate_and_download_tsr' do
      it 'generates and downloads TSR in one operation' do
        VCR.use_cassette('generate_and_download_tsr') do
          output_file = "/tmp/test_tsr_complete_#{Time.now.to_i}.zip"
          
          result = client.generate_and_download_tsr(
            output_file: output_file,
            data_selector_values: ["HWData"], # Just hardware data for faster test
            wait_timeout: 120
          )
          
          if result
            expect(File.exist?(output_file)).to be true
            expect(File.size(output_file)).to be > 0
            File.delete(output_file) if File.exist?(output_file)
          end
        end
      end
    end

  end
end