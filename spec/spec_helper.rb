# frozen_string_literal: true

if ENV["COVERAGE"] != "false"
  require "simplecov"
  require "simplecov_json_formatter"
  SimpleCov.formatters = [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::JSONFormatter]
  SimpleCov.start do
    track_files "lib/**/*.rb"
    enable_coverage :branch
    add_filter "/spec/"
    minimum_coverage line: 95, branch: 85
  end
end

require "vcr_browser_proxy"
require "vcr_browser_proxy/cuprite"
require "vcr"
require "webmock"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

# WebMock is loaded so the integration specs can prove a plain stub intercepts
# the browser's request, but it stays out of the way everywhere else.
WebMock.allow_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "tmp/rspec-status.txt"

  config.include BrowserClient

  # Browser specs need Chrome; run them with `rake e2e` or `E2E=1`.
  config.filter_run_excluding :e2e unless ENV["E2E"]

  config.after { VcrBrowserProxy.reset_configuration! }
end
