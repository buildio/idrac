# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Debug Blank Method" do
  it "shows the owner of various blank? methods" do
    # This will help us understand where the blank? methods are coming from
    puts "nil.blank? method owner: #{nil.method(:blank?).owner}"
    puts "String.blank? method owner: #{String.instance_method(:blank?).owner}"
    puts "false.blank? method owner: #{false.method(:blank?).owner}"
    puts "true.blank? method owner: #{true.method(:blank?).owner}"
    puts "false.blank? returns: #{false.blank?}"
    
    # Verify ActiveSupport blank? behavior for false
    expect(false.respond_to?(:empty?)).to eq(false)
  end
end 