# frozen_string_literal: true

RSpec.describe VcrBrowserProxy::CrossSiteCookies do
  subject(:rewriter) { described_class.new }

  def relayed_cookies(dest:, referer:, cookies: ["sid=1; Path=/; SameSite=Lax"])
    headers = { "Sec-Fetch-Dest" => dest, "Referer" => referer }.compact
    exchange = VcrBrowserProxy::Exchange.new(request_method: "GET", uri: URI("https://dam.example.com/login"),
                                             request_headers: headers)
    exchange.set_cookies = cookies
    rewriter.response(exchange)
    exchange.set_cookies
  end

  context "when the localhost test app navigates to the provider" do
    it "re-marks the provider's cookies SameSite=None; Secure so its redirects carry them" do
      expect(relayed_cookies(dest: "document",
                             referer: "http://localhost:61234/")).to eq(["sid=1; Path=/; SameSite=None; Secure"])
    end
  end

  context "when a cookie is already Secure" do
    it "doesn't add Secure twice" do
      cookies = relayed_cookies(dest: "document", referer: nil, cookies: ["sid=1; Secure; SameSite=Strict"])

      expect(cookies).to eq(["sid=1; Secure; SameSite=None"])
    end
  end

  context "when the cookie is set inside a third-party iframe" do
    it "leaves it as the site set it, so a flow that needs it fails as it would for a real user" do
      expect(relayed_cookies(dest: "iframe", referer: "http://localhost:61234/")).to eq(["sid=1; Path=/; SameSite=Lax"])
    end
  end

  context "when the iframe is same-site with the page that embeds it" do
    it "upgrades its cookies" do
      expect(relayed_cookies(dest: "iframe",
                             referer: "https://app.example.com/")).to eq(["sid=1; Path=/; SameSite=None; Secure"])
    end
  end

  context "when an iframe request's Origin isn't a URL" do
    it "treats it like a top-level request" do
      headers = { "Sec-Fetch-Dest" => "iframe", "Origin" => "http://[bad" }
      exchange = VcrBrowserProxy::Exchange.new(request_method: "GET", uri: URI("https://dam.example.com/login"),
                                               request_headers: headers)
      exchange.set_cookies = ["sid=1; SameSite=Lax"]
      rewriter.response(exchange)

      expect(exchange.set_cookies).to eq(["sid=1; SameSite=None; Secure"])
    end
  end

  context "when an iframe request carries no usable Referer" do
    it "treats it like a top-level request" do
      expect(relayed_cookies(dest: "iframe", referer: nil)).to eq(["sid=1; Path=/; SameSite=None; Secure"])
    end
  end
end
