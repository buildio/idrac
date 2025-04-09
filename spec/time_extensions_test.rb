# frozen_string_literal: true

require "spec_helper"

# This test specifically verifies that ActiveSupport's time-related extensions work
RSpec.describe "ActiveSupport Time Extensions" do
  it "provides the basic time unit conversions" do
    # Basic time unit conversions
    expect(1.second).to eq(1)
    expect(1.seconds).to eq(1)
    expect(1.minute).to eq(60)
    expect(1.minutes).to eq(60)
    expect(1.hour).to eq(60 * 60)
    expect(1.hours).to eq(60 * 60)
    expect(1.day).to eq(24 * 60 * 60)
    expect(1.days).to eq(24 * 60 * 60)
    expect(1.week).to eq(7 * 24 * 60 * 60)
    expect(1.weeks).to eq(7 * 24 * 60 * 60)
  end
  
  it "provides time calculation methods like ago and from_now" do
    # Calculate a time in the past
    past_time = 1.hour.ago
    expect(past_time).to be_a(Time)
    expect(past_time).to be < Time.now
    
    # Calculate a time in the future
    future_time = 2.days.from_now
    expect(future_time).to be_a(Time)
    expect(future_time).to be > Time.now
    
    # Verify the difference between now and the calculated times
    expect(Time.now - past_time).to be_within(10).of(1.hour)
    expect(future_time - Time.now).to be_within(10).of(2.days)
    
    # Print for manual verification
    puts "1 hour ago: #{1.hour.ago}"
    puts "2 days from now: #{2.days.from_now}"
    puts "3.weeks.from_now: #{3.weeks.from_now}"
  end
  
  it "provides other ActiveSupport time helpers" do
    expect(Time.now.beginning_of_day).to be_a(Time)
    expect(Time.now.end_of_day).to be_a(Time)
    expect(Time.now.tomorrow).to be_a(Time)
    expect(Time.now.yesterday).to be_a(Time)
    
    # Print for manual verification
    puts "Beginning of day: #{Time.now.beginning_of_day}"
    puts "End of day: #{Time.now.end_of_day}"
    puts "Tomorrow: #{Time.now.tomorrow}"
    puts "Yesterday: #{Time.now.yesterday}"
  end
end 