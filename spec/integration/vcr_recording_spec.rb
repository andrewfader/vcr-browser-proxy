# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Recording browser traffic with VCR" do
  around do |example|
    Dir.mktmpdir do |dir|
      VCR.configure do |c|
        c.cassette_library_dir = dir
        c.hook_into :excon
        c.allow_http_connections_when_no_cassette = true
      end
      @cassette_dir = dir
      example.run
    ensure
      VCR.eject_cassette while VCR.current_cassette
    end
  end

  let(:upstream) do
    FakeUpstream.new do |request|
      [200, { "Content-Type" => "text/plain" }, "upstream says #{request.path}"]
    end
  end

  after { upstream.stop }

  def cassette_text(name) = File.read(File.join(@cassette_dir, "#{name}.yml"))

  context "when the browser's request goes through the proxy inside a cassette" do
    it "records it on the first run and replays it once the upstream is gone" do
      proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[127.0.0.1]).start
      url = upstream.url("/widget")

      recorded = VCR.use_cassette("browser", record: :once) { via_proxy(url, proxy: proxy).body }
      upstream.stop
      replayed = VCR.use_cassette("browser", record: :none) { via_proxy(url, proxy: proxy).body }

      expect(recorded).to eq("upstream says /widget")
      expect(replayed).to eq(recorded)
      expect(cassette_text("browser")).to include("/widget")
    ensure
      proxy&.stop
    end

    it "puts the browser's calls and the server's own calls in the same cassette" do
      proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[127.0.0.1]).start

      VCR.use_cassette("both", record: :once) do
        via_proxy(upstream.url("/from-browser"), proxy: proxy)
        Excon.get(upstream.url("/from-server"))
      end

      expect(cassette_text("both")).to include("/from-browser", "/from-server")
    ensure
      proxy&.stop
    end

    it "records HTTPS the browser sent through a CONNECT tunnel" do
      proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[example.com], rewriters: [UpstreamTo.new(upstream)]).start

      VCR.use_cassette("tunnel", record: :once) { over_one_tunnel("app.example.com", %w[/one /two], proxy: proxy) }
      upstream.stop
      bodies = VCR.use_cassette("tunnel", record: :none) do
        over_one_tunnel("app.example.com", %w[/one /two], proxy: proxy).map(&:body)
      end

      expect(bodies).to eq(["upstream says /one", "upstream says /two"])
    ensure
      proxy&.stop
    end
  end

  context "when the browser asks for something the cassette doesn't have" do
    it "answers 502 and records VCR's refusal, so the spec fails where the gap is" do
      proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[127.0.0.1]).start
      VCR.use_cassette("empty", record: :once) {} # rubocop:disable Lint/EmptyBlock

      response = VCR.use_cassette("empty", record: :none) { via_proxy(upstream.url("/not-recorded"), proxy: proxy) }

      expect(response.code).to eq("502")
      expect(proxy.served.first[:error]).to include("VCR::Errors::UnhandledHTTPRequestError")
    ensure
      proxy&.stop
    end
  end

  context "when browser telemetry hits the proxy during recording" do
    it "keeps it out of the cassette" do
      proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[127.0.0.1]).start

      VCR.use_cassette("quiet", record: :once) do
        via_proxy(upstream.url("/page"), proxy: proxy)
        over_one_tunnel("update.googleapis.com", %w[/ping], proxy: proxy)
      end

      expect(cassette_text("quiet")).not_to include("googleapis")
    ensure
      proxy&.stop
    end
  end
end
