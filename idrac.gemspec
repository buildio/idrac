# frozen_string_literal: true

require_relative "lib/idrac/version"

Gem::Specification.new do |spec|
  spec.name = "idrac"
  spec.version = IDRAC::VERSION
  spec.authors = ["Jonathan Siegel"]
  spec.email = ["<248302+usiegj00@users.noreply.github.com>"]

  spec.summary = "API Client for Dell iDRAC"
  spec.description = "A Ruby client for the Dell iDRAC API"
  spec.homepage = "http://github.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0" # Updated to support Ruby 3.2.x

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # Instead of using git ls-files, use a more explicit approach
  spec.files = Dir[
    "lib/**/*",
    "bin/*",
    "README.md",
    "LICENSE.txt",
    "*.gemspec"
  ]
  spec.bindir = "bin"
  spec.executables = ["idrac"]
  spec.require_paths = ["lib"]

  # Dependencies - Using semantic versioning recommendations
  spec.add_dependency "httparty", "~> 0.21", ">= 0.21.0"
  spec.add_dependency "nokogiri", "~> 1.15", ">= 1.15.0"
  spec.add_dependency "faraday", "~> 2.7", ">= 2.7.0"
  spec.add_dependency "faraday-multipart", "~> 1.0", ">= 1.0.0"
  spec.add_dependency "thor", "~> 1.2", ">= 1.2.0"
  spec.add_dependency "base64", "~> 0.1", ">= 0.1.0"
  spec.add_dependency "colorize", "~> 1.1", ">= 1.1.0"
  spec.add_dependency "recursive-open-struct", "~> 1.1", ">= 1.1.0"
  spec.add_dependency "activesupport", "~> 6.0"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.4", ">= 2.4.0"
  spec.add_development_dependency "rake", "~> 13.0", ">= 13.0.0"
  spec.add_development_dependency "rspec", "~> 3.12", ">= 3.12.0"
  spec.add_development_dependency "debug", "~> 1.8", ">= 1.8.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
