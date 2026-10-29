# frozen_string_literal: true

RSpec.describe VcrBrowserProxy::Exchange do
  subject(:exchange) do
    described_class.new(request_method: "GET", uri: URI("https://idp.test/authorize"), request_headers: request_headers)
  end

  let(:request_headers) { {} }

  describe "#auth_scheme" do
    it "is :none without an Authorization header" do
      expect(exchange.auth_scheme).to eq(:none)
    end

    context "with Basic credentials" do
      let(:request_headers) { { "authorization" => "Basic dXNlcjpwYXNz" } }

      it("is :basic") { expect(exchange.auth_scheme).to eq(:basic) }
    end

    context "with a bearer token" do
      let(:request_headers) { { "Authorization" => "Bearer abc" } }

      it("is :other") { expect(exchange.auth_scheme).to eq(:other) }
    end
  end

  describe "#request_origin" do
    context "with an Origin header" do
      let(:request_headers) { { "Origin" => "http://localhost:61234", "Referer" => "https://elsewhere.test/" } }

      it("prefers it") { expect(exchange.request_origin).to eq("http://localhost:61234") }
    end

    context "with only a Referer, as headless Chrome sends on some CORS GETs" do
      let(:request_headers) { { "Referer" => "http://localhost:61234/login?next=/" } }

      it("derives the origin from it") { expect(exchange.request_origin).to eq("http://localhost:61234") }
    end

    context "with an opaque Origin" do
      let(:request_headers) { { "Origin" => "null", "Referer" => "https://app.test/page" } }

      it("falls back to the Referer") { expect(exchange.request_origin).to eq("https://app.test") }
    end

    context "with a Referer on the default port" do
      let(:request_headers) { { "Referer" => "https://app.test:443/page" } }

      it("leaves the port out") { expect(exchange.request_origin).to eq("https://app.test") }
    end

    context "with neither header" do
      it("is nil") { expect(exchange.request_origin).to be_nil }
    end

    context "with a Referer that isn't a URL" do
      let(:request_headers) { { "Referer" => "::not a url::" } }

      it("is nil") { expect(exchange.request_origin).to be_nil }
    end
  end

  describe "#request_cookie_names" do
    let(:request_headers) { { "Cookie" => "sid=1; theme=dark;; =orphan" } }

    it "lists the cookie names the browser sent, skipping empty ones" do
      expect(exchange.request_cookie_names).to eq(%w[sid theme])
    end
  end

  describe "#rewrite_location" do
    it "rewrites a single Location and keeps it a string" do
      exchange.response_headers = { "Location" => "http://a.test/x" }
      exchange.rewrite_location { |location| location.sub("a.test", "b.test") }

      expect(exchange.response_headers).to eq("Location" => "http://b.test/x")
    end

    it "rewrites every value of a repeated Location and keeps it a list" do
      exchange.response_headers = { "location" => ["http://a.test/1", "http://a.test/2"] }
      exchange.rewrite_location(&:upcase)

      expect(exchange.response_headers["location"]).to eq(["HTTP://A.TEST/1", "HTTP://A.TEST/2"])
    end

    it "leaves the other headers alone" do
      exchange.response_headers = { "Content-Type" => "text/html" }
      exchange.rewrite_location { |_location| "changed" }

      expect(exchange.response_headers).to eq("Content-Type" => "text/html")
    end
  end
end
