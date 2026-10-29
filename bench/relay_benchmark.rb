# frozen_string_literal: true

# Throughput of the proxy against a loopback upstream.
#
#   bundle exec ruby bench/relay_benchmark.rb
#   VCR_BROWSER_PROXY_LIB=/path/to/older/lib bundle exec ruby bench/relay_benchmark.rb   # compare a build
#
# Rows:
#   direct            Excon straight to the upstream: the floor.
#   proxied http      one plain proxied request per connection.
#   tunnel, tls       20 requests over one CONNECT tunnel to a TLS upstream, the way
#                     Chrome reuses a tunnel. Upstream connection reuse shows here.

own_lib = File.expand_path("../lib", __dir__)
if (other_lib = ENV.fetch("VCR_BROWSER_PROXY_LIB", nil))
  $LOAD_PATH.delete(own_lib)
  $LOAD_PATH.unshift(other_lib)
else
  $LOAD_PATH.unshift(own_lib)
end
require "benchmark/ips"
require "vcr_browser_proxy"
require_relative "../spec/support/fake_upstream"
require_relative "../spec/support/browser_client"
require_relative "../spec/support/upstream_to"

include BrowserClient # rubocop:disable Style/MixinUsage

Excon.defaults[:ssl_verify_peer] = false
BODY = "x" * Integer(ENV.fetch("BODY_BYTES", 2048))
REQUESTS_PER_TUNNEL = 20

plain = FakeUpstream.new { [200, { "Content-Type" => "text/plain" }, BODY] }
tls = FakeUpstream.new(tls: true) { [200, { "Content-Type" => "text/plain" }, BODY] }
http_proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[127.0.0.1]).start
tunnel_proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[example.com], rewriters: [UpstreamTo.new(tls)]).start
direct = Excon.new(plain.url, persistent: true)
paths = Array.new(REQUESTS_PER_TUNNEL) { |i| "/#{i}" }

loaded_from = $LOADED_FEATURES.grep(%r{/vcr_browser_proxy\.rb\z}).first
puts "vcr-browser-proxy from #{loaded_from}, #{BODY.bytesize}-byte bodies, #{RUBY_DESCRIPTION}"

Benchmark.ips do |x|
  x.config(warmup: 1, time: 4)
  x.report("direct") { direct.get(path: "/") }
  x.report("proxied http") { via_proxy(plain.url("/"), proxy: http_proxy) }
  x.report("tunnel, tls (#{REQUESTS_PER_TUNNEL} requests)") do
    over_one_tunnel("app.example.com", paths, proxy: tunnel_proxy)
  end
  x.compare!
end

connections_before = tls.connections
over_one_tunnel("app.example.com", paths, proxy: tunnel_proxy)
opened = tls.connections - connections_before
puts "upstream TLS connections for one tunnel of #{REQUESTS_PER_TUNNEL} requests: #{opened}"
