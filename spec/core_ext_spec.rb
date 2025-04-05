# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Core Extensions" do
  describe "Numeric Extensions" do
    describe "byte-related extensions" do
      it "provides correct byte conversions" do
        expect(1.byte).to eq(1)
        expect(1.kilobyte).to eq(1024)
        expect(1.megabyte).to eq(1024 * 1024)
        expect(2.megabytes).to eq(2 * 1024 * 1024)
        expect(1.gigabyte).to eq(1024 * 1024 * 1024)
        expect(1.terabyte).to eq(1024 * 1024 * 1024 * 1024)
        expect(1.petabyte).to eq(1024 * 1024 * 1024 * 1024 * 1024)
      end

      it "allows calculations across units" do
        expect(8.gigabytes / 1.megabyte).to eq(8 * 1024)
        expect(8192.megabytes / 1.gigabyte).to eq(8)
      end
    end

    describe "time-related extensions" do
      it "provides correct time conversions" do
        expect(1.minute).to eq(60)
        expect(1.hour).to eq(60 * 60)
        expect(1.day).to eq(24 * 60 * 60)
        expect(1.week).to eq(7 * 24 * 60 * 60)
      end
    end
  end

  describe "blank? method" do
    it "returns true for nil" do
      expect(nil.blank?).to be true
    end

    it "returns true for empty strings" do
      expect("".blank?).to be true
      expect("  ".blank?).to be true
    end

    it "returns false for non-empty strings" do
      expect("hello".blank?).to be false
    end

    it "returns true for empty arrays" do
      expect([].blank?).to be true
    end

    it "returns false for non-empty arrays" do
      expect([1, 2, 3].blank?).to be false
    end

    it "returns true for empty hashes" do
      expect({}.blank?).to be true
    end

    it "returns false for non-empty hashes" do
      expect({key: 'value'}.blank?).to be false
    end
  end
end 