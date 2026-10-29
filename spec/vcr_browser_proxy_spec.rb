# frozen_string_literal: true

RSpec.describe VcrBrowserProxy do
  subject(:proxy) { described_class.new(allowed_host_suffixes: allowed, **options).start }

  let(:allowed) { %w[127.0.0.1] }
  let(:options) { {} }
  let(:responder) { ->(_request) { [200, { "Content-Type" => "text/plain" }, "hello from upstream"] } }
  let!(:upstream) { FakeUpstream.new(&responder) }

  after do
    proxy.stop
    upstream.stop
  end

  describe "relaying a browser request" do
    context "when the host is on the allowlist" do
      it "re-issues the request upstream and relays the response" do
        response = via_proxy(upstream.url("/greeting"))

        expect(response.code).to eq("200")
        expect(response.body).to eq("hello from upstream")
        expect(upstream.requests.pop.path).to eq("/greeting")
      end

      it "forwards the query string, headers and body of a POST" do
        form = { "Content-Type" => "application/x-www-form-urlencoded", "X-Trace" => "1" }
        via_proxy(upstream.url("/token?grant=code"), method: :post, body: "code=abc", headers: form)

        request = upstream.requests.pop
        expect(request.request_method).to eq("POST")
        expect(request.path).to eq("/token?grant=code")
        expect(request.body).to eq("code=abc")
        expect(request.header("x-trace")).to eq("1")
      end

      it "drops hop-by-hop headers in both directions" do
        via_proxy(upstream.url("/"), headers: { "Proxy-Authorization" => "Basic secret", "TE" => "trailers" })

        request = upstream.requests.pop
        expect(request.headers).not_to include("proxy-authorization", "te")
      end

      it "records what it served, for the spec to assert on" do
        via_proxy(upstream.url("/page"), headers: { "Cookie" => "a=1; b=2", "Authorization" => "Bearer x" })

        expect(proxy.served).to contain_exactly(
          include(host: "127.0.0.1", method: "GET", status: 200, ignored: false, auth: :other, cookie_names: %w[a b])
        )
      end
    end

    context "when the host is not on the allowlist, as with browser telemetry" do
      let(:allowed) { %w[example.com] }

      it "answers with an empty 204 and never calls upstream" do
        response = via_proxy(upstream.url("/ping"))

        expect(response.code).to eq("204")
        expect(response.body).to be_nil
        expect(upstream.requests).to be_empty
        expect(proxy.served.first).to include(ignored: true, status: 204)
      end
    end

    context "when the upstream redirects" do
      let(:responder) { ->(_) { [302, { "Location" => "https://idp.test/mfa" }, ""] } }

      it "relays the redirect so the browser follows it through the proxy" do
        response = via_proxy(upstream.url("/authorize"))

        expect(response.code).to eq("302")
        expect(response["Location"]).to eq("https://idp.test/mfa")
        expect(upstream.requests.size).to eq(1)
      end
    end

    context "when the upstream sets several cookies" do
      let(:responder) { ->(_) { [200, { "Set-Cookie" => ["a=1; Path=/", "b=2; Path=/"] }, ""] } }

      it "relays each Set-Cookie on its own line" do
        expect(via_proxy(upstream.url("/")).get_fields("Set-Cookie")).to eq(["a=1; Path=/", "b=2; Path=/"])
      end
    end

    context "when the browser asks only for the headers" do
      let(:responder) { ->(_) { [200, { "Content-Type" => "text/plain" }, "a body of 21 bytes..."] } }

      it "relays the length a GET would get, and no body" do
        response = via_proxy(upstream.url("/file"), method: :head)

        expect(response["Content-Length"]).to eq("21")
        expect(response.body).to be_nil
      end
    end

    context "when the upstream answers 304 Not Modified" do
      let(:responder) { ->(_) { [304, { "ETag" => "\"v1\"" }, ""] } }

      it "relays it without a body or a length" do
        response = via_proxy(upstream.url("/cached"))

        expect(response.code).to eq("304")
        expect(response["Content-Length"]).to be_nil
      end
    end

    context "when the upstream cannot be reached" do
      let(:options) { { connect_timeout: 2, idempotent_retries: 1 } }

      it "answers 502 and records the error" do
        closed_port = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
        response = via_proxy("http://127.0.0.1:#{closed_port}/")

        expect(response.code).to eq("502")
        expect(proxy.served.first[:error]).to start_with("Excon::Error")
      end
    end
  end

  describe "the allowlist" do
    subject(:proxy) { described_class.new(allowed_host_suffixes: %w[Example.com]) }

    after { proxy.stop }

    it "matches a host and its subdomains, case-insensitively" do
      expect(proxy.host_allowed?("example.com")).to be(true)
      expect(proxy.host_allowed?("Login.EXAMPLE.com")).to be(true)
    end

    it "matches only on a label boundary" do
      expect(proxy.host_allowed?("notexample.com")).to be(false)
      expect(proxy.host_allowed?("example.com.evil.test")).to be(false)
    end

    it "allows nothing for a missing host" do
      expect(proxy.host_allowed?(nil)).to be(false)
    end
  end

  describe "HTTPS through a CONNECT tunnel" do
    let(:allowed) { %w[example.com] }

    it "presents the certificate whose SPKI it reports for Chrome's allowlist" do
      status, ssl = open_tunnel("example.com")
      presented = [OpenSSL::Digest::SHA256.digest(ssl.peer_cert.public_key.public_to_der)].pack("m0")

      expect(status).to eq("HTTP/1.1 200 Connection established\r\n")
      expect(presented).to eq(proxy.certificate_spki_sha256)
    ensure
      ssl&.close
    end

    it "negotiates HTTP/1.1 even when the browser offers h2 first" do
      _status, ssl = open_tunnel("example.com", alpn: %w[h2 http/1.1])

      expect(ssl.alpn_protocol).to eq("http/1.1")
    ensure
      ssl&.close
    end

    it "serves every request the browser sends over one tunnel" do
      responses = over_one_tunnel("telemetry.example.org", %w[/a /b /c])

      expect(responses.map(&:code)).to eq(%w[204 204 204])
      expect(proxy.served.size).to eq(3)
    end

    it "serves two requests the browser sent back to back" do
      _status, ssl = open_tunnel("telemetry.example.org")
      ssl.write("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n")
      ssl.flush

      Timeout.timeout(5) { true until proxy.served.size == 2 }
      expect(proxy.served.map { |entry| URI(entry[:url]).path }).to eq(%w[/a /b])
    ensure
      ssl&.close
    end

    context "when a disallowed tunnel sits idle" do
      let(:options) { { telemetry_idle_timeout: 0.2 } }

      it "closes it after the short telemetry timeout instead of parking a thread" do
        logged = []
        proxy = described_class.new(allowed_host_suffixes: %w[example.com], telemetry_idle_timeout: 0.2,
                                    logger: ->(line) { logged << line }).start
        _status, ssl = open_tunnel("telemetry.example.org", proxy: proxy)

        Timeout.timeout(5) { true until logged.any? { |line| line.include?("tunnel idle timeout") } }
        expect(logged.grep(/idle timeout for telemetry\.example\.org after 0 request/)).not_to be_empty
      ensure
        ssl&.close
        proxy&.stop
      end
    end

    context "when the browser drops the tunnel without a TLS goodbye" do
      it "logs it as the tunnel closing, not as an error" do
        logged = []
        proxy = described_class.new(allowed_host_suffixes: %w[example.com], logger: ->(line) { logged << line }).start
        _status, ssl = open_tunnel("example.com", proxy: proxy)
        ssl.to_io.close

        Timeout.timeout(5) { true until logged.any? { |line| line.include?("tunnel closed") } }
        expect(logged.grep(/error/)).to be_empty
      ensure
        proxy&.stop
      end
    end
  end

  describe "upstream connections" do
    let(:allowed) { %w[example.com] }

    it "reuses one upstream connection for a tunnel's idempotent requests" do
      rewriter = UpstreamTo.new(upstream)
      proxy = described_class.new(allowed_host_suffixes: %w[example.com], rewriters: [rewriter]).start

      over_one_tunnel("app.example.com", %w[/1 /2 /3], proxy: proxy)

      expect(upstream.requests.size).to eq(3)
      expect(upstream.connections).to eq(1)
    ensure
      proxy&.stop
    end

    it "sends a POST on a fresh connection, so a stale one can't swallow it" do
      proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1]).start

      2.times { via_proxy(upstream.url("/submit"), method: :post, body: "x", proxy: proxy) }

      expect(upstream.connections).to eq(2)
    ensure
      proxy&.stop
    end

    context "when the upstream says it is closing the connection" do
      it "opens a new one for the next request" do
        served = 0
        closing = FakeUpstream.new do |_request|
          served += 1
          [200, { "Connection" => "close" }, "response #{served}"]
        end
        proxy = described_class.new(allowed_host_suffixes: %w[example.com], rewriters: [UpstreamTo.new(closing)]).start

        bodies = over_one_tunnel("app.example.com", %w[/1 /2], proxy: proxy).map(&:body)

        expect(bodies).to eq(["response 1", "response 2"])
      ensure
        proxy&.stop
        closing&.stop
      end
    end

    context "when the upstream silently dropped the connection the proxy was about to reuse" do
      it "retries the idempotent request on a new connection and logs the retry" do
        logged = []
        dropping = FakeUpstream.new(drop_idle: true) { |request| [200, {}, "served #{request.path}"] }
        proxy = described_class.new(allowed_host_suffixes: %w[example.com], rewriters: [UpstreamTo.new(dropping)],
                                    logger: ->(line) { logged << line }).start

        bodies = over_one_tunnel("app.example.com", %w[/1 /2], proxy: proxy).map(&:body)

        expect(bodies).to eq(["served /1", "served /2"])
        expect(dropping.connections).to eq(2)
        expect(logged.grep(%r{retrying GET .*Excon::Error::Socket \(attempt 2/3\)})).not_to be_empty
      ensure
        proxy&.stop
        dropping&.stop
      end
    end

    context "when the upstream is slower than the read timeout once" do
      it "retries an idempotent request after a pause" do
        calls = 0
        slow_once = FakeUpstream.new do |_request|
          calls += 1
          sleep 1.5 if calls == 1
          [200, {}, "call #{calls}"]
        end
        proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1], read_timeout: 1).start

        expect(via_proxy(slow_once.url("/"), proxy: proxy).body).to eq("call 2")
      ensure
        proxy&.stop
        slow_once&.stop
      end

      it "doesn't retry a POST, which may already have taken effect" do
        calls = 0
        slow = FakeUpstream.new do |_request|
          calls += 1
          sleep 1.5
          [200, {}, ""]
        end
        proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1], read_timeout: 1).start

        expect(via_proxy(slow.url("/charge"), method: :post, body: "x", proxy: proxy).code).to eq("502")
        expect(calls).to eq(1)
      ensure
        proxy&.stop
        slow&.stop
      end
    end
  end

  describe "rewriters" do
    let(:rewriter) do
      Class.new do
        def request(exchange) = exchange.uri = URI.join(exchange.uri, "/rewritten")
        def response(exchange) = exchange.response_headers["X-Rewritten"] = "yes"
      end.new
    end
    let(:responder) { ->(request) { [200, {}, request.path] } }
    let(:options) { { rewriters: [rewriter] } }

    it "lets a rewriter change the request before it goes upstream and the response after" do
      response = via_proxy(upstream.url("/original"))

      expect(response.body).to eq("/rewritten")
      expect(response["X-Rewritten"]).to eq("yes")
    end

    it "accepts a rewriter that only handles one side" do
      only_response = Class.new { def response(exchange) = exchange.status = 201 }.new
      proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1], rewriters: [only_response]).start

      expect(via_proxy(upstream.url("/"), proxy: proxy).code).to eq("201")
    ensure
      proxy&.stop
    end
  end

  describe "requests that can't be served" do
    let(:allowed) { %w[example.com] }

    def raw_exchange(bytes, proxy: self.proxy)
      socket = TCPSocket.new(proxy.host, proxy.port)
      socket.write(bytes)
      socket.close_write
      socket.read
    ensure
      socket&.close
    end

    it "answers a malformed request with a 400" do
      expect(raw_exchange("GET\r\n\r\n")).to start_with("HTTP/1.1 400 Bad Request").and include("bad request line")
    end

    it "answers a plain request whose target isn't a URL with a 400" do
      expect(raw_exchange("GET http://[bad HTTP/1.1\r\n\r\n")).to start_with("HTTP/1.1 400 Bad Request")
    end

    it "logs a CONNECT that is followed by plain text instead of a TLS handshake" do
      logged = []
      proxy = described_class.new(allowed_host_suffixes: %w[example.com], logger: ->(line) { logged << line }).start

      raw_exchange("CONNECT app.example.com:443 HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n", proxy: proxy)

      expect(logged.grep(/TLS accept failed for app\.example\.com/)).not_to be_empty
    ensure
      proxy&.stop
    end

    it "answers a malformed request inside a tunnel with a 400" do
      _status, ssl = open_tunnel("app.example.com")
      ssl.write("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
      ssl.flush

      expect(ssl.gets).to eq("HTTP/1.1 400 Bad Request\r\n")
    ensure
      ssl&.close
    end

    it "shrugs off a browser that resets the connection mid-request" do
      logged = []
      proxy = described_class.new(allowed_host_suffixes: %w[example.com], logger: ->(line) { logged << line }).start
      socket = TCPSocket.new(proxy.host, proxy.port)
      socket.write("GET http://app.example.com/ HTTP/1.1\r\n")
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      socket.close

      Timeout.timeout(5) { true until logged.any? { |line| line.match?(/connection closed|malformed/) } }
      expect(logged.grep(/connection error/)).to be_empty
    ensure
      proxy&.stop
    end

    it "gives up quietly when the browser leaves before the response is written" do
      logged = []
      slow = FakeUpstream.new do |_request|
        sleep 0.3
        [200, {}, "x" * 1_000_000]
      end
      proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1], logger: ->(line) { logged << line }).start
      socket = TCPSocket.new(proxy.host, proxy.port)
      socket.write("GET #{slow.url("/")} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      socket.close

      Timeout.timeout(5) { true until logged.any? { |line| line.include?("browser closed during") } }
      expect(logged.grep(/upstream error/)).to be_empty
    ensure
      proxy&.stop
      slow&.stop
    end

    it "keeps accepting after a failed accept" do
      proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1])
      server = proxy.instance_variable_get(:@server)
      failures = [Errno::ECONNABORTED]
      allow(server).to receive(:accept).and_wrap_original do |accept|
        failures.empty? ? accept.call : raise(failures.shift)
      end
      proxy.start

      expect(via_proxy(upstream.url("/"), proxy: proxy).code).to eq("200")
    ensure
      proxy&.stop
    end
  end

  describe "logging" do
    it "names an unparseable redirect target instead of failing the relay" do
      logged = []
      odd = FakeUpstream.new { [302, { "Location" => "http://[not a url" }, ""] }
      proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1], logger: ->(line) { logged << line }).start

      expect(via_proxy(odd.url("/"), proxy: proxy).code).to eq("302")
      expect(logged.grep(/-> \(unparseable URL\)/)).not_to be_empty
    ensure
      proxy&.stop
      odd&.stop
    end

    it "logs paths without query strings, which can carry authorization codes" do
      logged = []
      proxy = described_class.new(allowed_host_suffixes: %w[127.0.0.1], logger: ->(line) { logged << line }).start

      via_proxy(upstream.url("/callback?code=secret"), proxy: proxy)

      expect(logged.grep(/relayed 200 GET/)).not_to be_empty
      expect(logged.join).not_to include("secret")
    ensure
      proxy&.stop
    end
  end

  describe "lifecycle" do
    it "runs stop hooks with the proxy, once" do
      stopped = []
      proxy = described_class.new(on_stop: [->(stopping) { stopped << stopping }]).start

      2.times { proxy.stop }

      expect(stopped).to eq([proxy])
      expect(proxy).not_to be_running
    end

    it "is idempotent to start" do
      proxy = described_class.new
      started = proxy.start

      expect(proxy.start).to be(started)
    ensure
      proxy&.stop
    end

    describe ".open" do
      it "makes the proxy current for the block and stops it afterwards" do
        seen = nil
        described_class.open(allowed_host_suffixes: %w[example.com]) { |open_proxy| seen = open_proxy }

        expect(seen).to be_a(described_class)
        expect(seen).not_to be_running
        expect(described_class.current).to be_nil
      end

      it "restores the previous current proxy even when the block raises" do
        outer = described_class.new
        described_class.current = outer

        expect { described_class.open { raise "boom" } }.to raise_error("boom")
        expect(described_class.current).to be(outer)
      ensure
        described_class.current = nil
        outer&.stop
      end
    end
  end

  describe "configuration" do
    it "starts every proxy from the configured defaults" do
      described_class.configure do |config|
        config.allowed_host_suffixes = %w[okta.com]
        config.telemetry_idle_timeout = 1
      end
      proxy = described_class.new

      expect(proxy.allowed_host_suffixes).to eq(%w[okta.com])
    ensure
      proxy&.stop
    end

    it "lets keyword arguments override the defaults" do
      described_class.configure { |config| config.allowed_host_suffixes = %w[okta.com] }
      proxy = described_class.new(allowed_host_suffixes: %w[box.com])

      expect(proxy.allowed_host_suffixes).to eq(%w[box.com])
    ensure
      proxy&.stop
    end

    it "builds rewriters per proxy from a factory, so stateful rewriters start fresh" do
      described_class.configure { |config| config.rewriters = -> { [Object.new] } }
      first = described_class.new
      second = described_class.new

      expect(first.instance_variable_get(:@rewriters)).not_to eq(second.instance_variable_get(:@rewriters))
    ensure
      first&.stop
      second&.stop
    end

    it "rejects an option it doesn't know" do
      expect { described_class.new(allowd_host_suffixes: []) }.to raise_error(ArgumentError, /allowd_host_suffixes/)
    end
  end
end
