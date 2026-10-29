# frozen_string_literal: true

RSpec.describe VcrBrowserProxy::RedirectOrigin do
  subject(:rewriter) { described_class.new(registered_origin: "http://localhost:3000/") }

  def exchange(location: nil, referer: nil, origin: nil)
    headers = { "Referer" => referer, "Origin" => origin }.compact
    VcrBrowserProxy::Exchange.new(request_method: "GET", uri: URI("https://idp.test/authorize"),
                                  request_headers: headers).tap do |e|
      e.response_headers = location ? { "Location" => location } : {}
    end
  end

  def relay(exchange)
    rewriter.request(exchange)
    rewriter.response(exchange)
    exchange.response_headers["Location"]
  end

  context "when the provider redirects to the registered callback while Capybara serves on another port" do
    it "moves the redirect onto the port the browser is using" do
      redirect = exchange(location: "http://localhost:3000/auth/callback?code=abc", referer: "http://localhost:61234/login")

      expect(relay(redirect)).to eq("http://localhost:61234/auth/callback?code=abc")
    end
  end

  context "when the redirect comes after the browser has left the app for the provider's pages" do
    it "remembers the app's port from an earlier request" do
      relay(exchange(referer: "http://localhost:61234/"))
      from_mfa_page = exchange(location: "http://localhost:3000/cb", referer: "https://idp.test/mfa")

      expect(relay(from_mfa_page)).to eq("http://localhost:61234/cb")
    end
  end

  context "when the app is reached as 127.0.0.1" do
    it "uses that origin" do
      expect(relay(exchange(location: "http://localhost:3000/cb", origin: "http://127.0.0.1:5555"))).to eq("http://127.0.0.1:5555/cb")
    end
  end

  context "when Capybara happens to serve on the registered port" do
    it "leaves the redirect alone" do
      expect(relay(exchange(location: "http://localhost:3000/cb", referer: "http://localhost:3000/"))).to eq("http://localhost:3000/cb")
    end
  end

  context "when nothing has told it the app's port yet" do
    it "leaves the redirect alone" do
      expect(relay(exchange(location: "http://localhost:3000/cb"))).to eq("http://localhost:3000/cb")
    end
  end

  context "with a redirect somewhere else" do
    it "leaves it alone" do
      expect(relay(exchange(location: "https://idp.test/mfa", referer: "http://localhost:61234/"))).to eq("https://idp.test/mfa")
    end
  end

  context "with requests from pages that aren't the local app" do
    it "doesn't mistake them for the app's origin" do
      relay(exchange(referer: "http://localhost:61234/"))
      relay(exchange(referer: "https://idp.test/login"))
      relay(exchange(referer: "::bad::"))
      relay(exchange(origin: "http://[bad"))

      expect(relay(exchange(location: "http://localhost:3000/cb"))).to eq("http://localhost:61234/cb")
    end
  end
end
