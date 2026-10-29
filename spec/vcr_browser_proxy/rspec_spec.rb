# frozen_string_literal: true

require "vcr_browser_proxy/rspec"

RSpec.describe "the :vcr_browser_proxy example tag" do
  it "runs the example with a started proxy as the current one", :vcr_browser_proxy do
    expect(vcr_browser_proxy).to be_running
    expect(VcrBrowserProxy.current).to be(vcr_browser_proxy)
  end

  it "takes proxy options from the tag", vcr_browser_proxy: { allowed_host_suffixes: %w[okta.com] } do
    expect(vcr_browser_proxy.allowed_host_suffixes).to eq(%w[okta.com])
  end

  it "stops the proxy and clears it as current once the example finishes, even when it fails" do
    seen = []
    group = RSpec.describe("a tagged group") do
      # A fixture example that fails on purpose.
      it("fails", :vcr_browser_proxy) do # rubocop:disable RSpec/NoExpectationExample
        seen << vcr_browser_proxy
        raise "boom"
      end
    end

    group.run(RSpec::Core::NullReporter)

    expect(seen.size).to eq(1)
    expect(seen.first).not_to be_running
    expect(VcrBrowserProxy.current).to be_nil
  ensure
    RSpec.world.example_groups.delete(group)
  end
end
