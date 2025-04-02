# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# Add a task that tags and pushes to the repository and builds 
# the gem and pushes it to rubygems.org.
# Depend on the build task to ensure the gem is up to date.
task :release => [:build] do
  system "git tag v#{IDRAC::VERSION}"
  system "git push --tags"
  system "gem push pkg/idrac-#{IDRAC::VERSION}.gem"
end
