# frozen_string_literal: true

require "spec_helper"

# This test specifically verifies that ActiveSupport's byte-related extensions work
RSpec.describe "ActiveSupport Byte Extensions" do
  it "provides all byte conversion methods" do
    # Test byte methods
    expect(1.byte).to eq(1)
    expect(1.bytes).to eq(1)
    
    # Test kilobyte methods
    expect(1.kilobyte).to eq(1024)
    expect(1.kilobytes).to eq(1024)
    
    # Test megabyte methods
    expect(1.megabyte).to eq(1024 * 1024)
    expect(1.megabytes).to eq(1024 * 1024)
    
    # Test gigabyte methods
    expect(1.gigabyte).to eq(1024 * 1024 * 1024)
    expect(1.gigabytes).to eq(1024 * 1024 * 1024)
    
    # Test terabyte methods
    expect(1.terabyte).to eq(1024 * 1024 * 1024 * 1024)
    expect(1.terabytes).to eq(1024 * 1024 * 1024 * 1024)
    
    # Test petabyte methods
    expect(1.petabyte).to eq(1024 * 1024 * 1024 * 1024 * 1024)
    expect(1.petabytes).to eq(1024 * 1024 * 1024 * 1024 * 1024)
    
    # Test calculations between units
    expect(1.gigabyte / 1.megabyte).to eq(1024)
    expect(1.5.gigabytes).to eq(1.5 * 1024 * 1024 * 1024)
    
    # Print result to verify
    puts "1 petabyte = #{1.petabyte} bytes"
    puts "2.5 gigabytes = #{2.5.gigabytes} bytes"
  end
end 