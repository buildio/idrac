# frozen_string_literal: true

source "https://rubygems.org"

ruby "3.3.5"

# Specify your gem's dependencies in idrac.gemspec
gemspec

# Standard library gems that will be removed from default gems in future Ruby versions
gem "csv"
gem "ostruct"

# These dependencies are already specified in the gemspec
# with specific versions, so we don't need to specify them here

group :development, :test do
  gem "webmock"
  gem "vcr"

  # activesupport below 8.1 passes quirks_mode: to JSON.generate, which json 3
  # removed, so `hash.to_json` raises "unknown keyword: quirks_mode" on that
  # pair. The gemspec allows activesupport >= 7.0, so CI runs both ends: the
  # modern pair by default, and the oldest supported one via these variables.
  # See .github/workflows/ci.yml.
  gem "activesupport", ENV.fetch("ACTIVESUPPORT_VERSION", ">= 8.1")
  gem "json", ENV.fetch("JSON_VERSION", ">= 3.0")
end
