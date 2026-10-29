# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

desc "Run the specs that drive real Chrome through the proxy"
task :e2e do
  ENV["E2E"] = "1"
  Rake::Task[:spec].invoke
end

desc "Benchmark the proxy against a loopback upstream"
task :bench do
  ruby "bench/relay_benchmark.rb"
end

task default: %i[rubocop spec]
