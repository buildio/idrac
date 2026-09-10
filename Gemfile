# frozen_string_literal: true

source "https://rubygems.org"

ruby "3.3.5"

# Specify your gem's dependencies in idrac.gemspec
gemspec

# Standard library gems that will be removed from default gems in future Ruby versions
gem "csv"
gem "ostruct"

# json 3.x drops the quirks_mode keyword that the JSON encoding in these specs
# still relies on, so every example errors with "unknown keyword: quirks_mode".
# Hold at 2.x until that is sorted upstream.
gem "json", "~> 2.19"

# These dependencies are already specified in the gemspec
# with specific versions, so we don't need to specify them here

group :development, :test do
  gem "webmock"
  gem "vcr"
  gem "activesupport", "~> 7.0"
end
