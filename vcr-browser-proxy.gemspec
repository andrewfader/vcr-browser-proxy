# frozen_string_literal: true

require_relative "lib/vcr_browser_proxy/version"

Gem::Specification.new do |spec|
  spec.name = "vcr-browser-proxy"
  spec.version = VcrBrowserProxy::VERSION
  spec.authors = ["Andrew Fader"]
  spec.email = ["fader@yagni.co"]
  spec.summary = "Record a real browser's HTTPS into the same VCR cassette as your server's calls"
  spec.description = <<~TEXT
    A threaded MITM forward proxy for Capybara/Cuprite system tests. It re-issues
    each browser request through Excon, so VCR and WebMock see browser traffic
    (an OAuth login, a third-party widget, a presigned S3 fetch) the same way
    they see server traffic. No EventMachine, one certificate for every host.
  TEXT
  spec.homepage = "https://github.com/andrewfader/vcr-browser-proxy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.add_dependency "excon", ">= 0.100"
  spec.add_dependency "rack", ">= 2.2"
end
