# frozen_string_literal: true

require "spec_helper"
require "idrac"

RSpec.describe IDRAC do
  it "has a version number" do
    expect(IDRAC::VERSION).not_to be nil
  end
end
