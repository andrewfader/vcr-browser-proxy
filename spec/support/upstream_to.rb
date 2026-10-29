# frozen_string_literal: true

# A rewriter that sends a tunnel's requests (https://app.example.com/x) to a
# FakeUpstream on loopback (http://127.0.0.1:<port>/x), so a spec can drive the
# real CONNECT path without DNS for a made-up host.
class UpstreamTo
  def initialize(upstream)
    @upstream = upstream
  end

  def request(exchange)
    exchange.uri = URI(@upstream.url(exchange.uri.request_uri))
  end
end
