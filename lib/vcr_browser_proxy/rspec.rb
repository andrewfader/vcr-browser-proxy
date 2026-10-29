# frozen_string_literal: true

require "vcr_browser_proxy"

# Tag an example `vcr_browser_proxy: true` (or a hash of proxy options) to run
# it with a started proxy as VcrBrowserProxy.current, stopped afterwards:
#
#   it "signs in", :vcr, vcr_browser_proxy: { allowed_host_suffixes: %w[okta.com] } do
#     driven_by :cuprite_vcr_proxy
#     ...
#   end
#
# The example can read the proxy as `vcr_browser_proxy`.
class VcrBrowserProxy
  module RSpec
    def vcr_browser_proxy
      VcrBrowserProxy.current
    end
  end
end

RSpec.configure do |config|
  config.include VcrBrowserProxy::RSpec, :vcr_browser_proxy
  config.around(:each, :vcr_browser_proxy) do |example|
    options = example.metadata[:vcr_browser_proxy]
    options = {} unless options.is_a?(Hash)
    VcrBrowserProxy.open(**options) { example.run }
  end
end
