# vcr-browser-proxy

Record a real browser's HTTPS into the same VCR cassette as your server's own calls.

System specs that drive a real OAuth login, a third-party widget, or a
presigned S3 download have a gap: VCR only sees requests made from the Ruby
process, and the browser's requests go straight out. `vcr-browser-proxy` is a
forward proxy for Chrome that re-issues every browser request through
[Excon](https://github.com/excon/excon). VCR (`hook_into :excon`) and WebMock's
Excon adapter then see the browser's traffic exactly as they see the server's:
record once against the real provider, replay hermetically in CI.

- **No EventMachine.** One Ruby thread per connection, so a slow upstream
  stalls only its own connection. (puffing-billy generates a keypair per host on
  its single reactor thread and patches `Kernel#sleep` process-wide.)
- **One certificate for every host**, generated at boot. Chrome is told to trust
  exactly that key, through `--ignore-certificate-errors-spki-list`.
- **An allowlist.** Hosts outside it get an empty `204` and never reach Excon,
  so Chrome's background telemetry can't pollute a cassette or break a replay.
- **Redirects are relayed, not followed**, so the browser walks a login flow
  host by host, through the proxy.

## Installation

```ruby
# Gemfile
group :test do
  gem "vcr-browser-proxy"
end
```

Capybara and Cuprite are optional; the Cuprite helpers load them when you call
them.

## Usage with Capybara and Cuprite

```ruby
# spec/support/vcr_browser_proxy.rb
require "vcr_browser_proxy/cuprite"
require "vcr_browser_proxy/rspec"

VcrBrowserProxy.configure do |config|
  config.allowed_host_suffixes = %w[okta.com oktacdn.com]
  # A callable, so each proxy gets fresh rewriters (RedirectOrigin keeps state).
  config.rewriters = lambda do
    [
      VcrBrowserProxy::RedirectOrigin.new(registered_origin: "http://localhost:3000"),
      VcrBrowserProxy::CrossSiteCookies.new
    ]
  end
  config.on_stop = [VcrBrowserProxy::Cuprite.retire_sessions]
end

VcrBrowserProxy::Cuprite.register_driver(base_options: { headless: true })
```

```ruby
RSpec.describe "Signing in with the identity provider", :vcr, type: :system do
  it "lands on the dashboard", :vcr_browser_proxy do
    driven_by :cuprite_vcr_proxy

    visit "/login"
    click_on "Sign in with Okta"
    # ...the real Okta pages, recorded into this example's cassette
  end
end
```

The `:vcr_browser_proxy` tag starts a proxy, makes it `VcrBrowserProxy.current`
for the example and stops it afterwards. Pass options in the tag
(`vcr_browser_proxy: { allowed_host_suffixes: %w[box.com] }`) to override the
configured defaults. Without RSpec, `VcrBrowserProxy.open(**options) { |proxy| ... }`
does the same around a block.

VCR links a new thread's cassette context to the thread that inserted the
cassette, so the proxy's per-connection threads record into the example's
cassette with no extra wiring (VCR 6.x).

Chrome skips the proxy for `localhost` and `127.0.0.1`, so the app under test is
reached directly. `register_driver` drops Cuprite's `url_blacklist`: Ferrum
implements it by pausing every request with CDP's `Fetch.enable`, and a paused
navigation that must CONNECT through an upstream proxy never does.

### Retiring browsers

Capybara keeps sessions in a pool, and a browser launched against one proxy
keeps using that proxy's port after the proxy stops. `Cuprite.retire_sessions`
is an `on_stop` hook that quits and unpools every session using the proxy's
driver; `after_quit:` receives each retired session and the sessions still
pooled, for anything else to tear down. It reaches Capybara's private
`session_pool`, which is the only handle on pooled sessions.

## Rewriters

A rewriter is any object with `request(exchange)` and/or `response(exchange)`.
They run in order: `request` before the upstream call, where it may replace
`exchange.uri`, and `response` after it, where it may edit `status`,
`response_headers` and `set_cookies`. `exchange.request_origin` gives the page
that issued the request (Origin, falling back to Referer), and
`exchange.rewrite_location { |location| ... }` edits redirects.

- `RedirectOrigin` moves redirects aimed at the callback origin you registered
  with the provider onto the ephemeral port Capybara is actually serving on.
- `CrossSiteCookies` re-marks relayed cookies `SameSite=None; Secure`, because
  `http://localhost` is cross-site to every provider. Cookies set inside a
  third-party iframe are left as the site set them, so a flow that depends on
  them fails the way it would in a real browser.

A rewriter can also stand in for DNS in a test, sending a made-up host to a
local server (`spec/e2e` does this for its fake identity provider).

## Diagnostics

`proxy.served` lists every request the proxy answered: host, method, status,
URL, whether it was ignored, any upstream error, the Authorization scheme
(`:none`, `:basic`, `:other`), the cookie names sent, and the `Sec-Fetch-*` and
Referer headers. Pass `logger: ->(line) { warn line }` to see each tunnel and
relay. Logged URLs omit query strings, which can carry authorization codes. A
browser closing an idle tunnel without a TLS goodbye is logged as the tunnel
closing, not as an error.

A request the cassette doesn't hold gets a `502`, and `served` records VCR's
error, so a replay fails where the gap is.

## Behaviour on the wire

- HTTP/1.1 only; the proxy selects `http/1.1` by ALPN, since a browser that
  negotiated h2 over the tunnel would send frames it can't read.
- Request bodies by `Content-Length` or chunked; malformed requests get a `400`.
- `HEAD` relays the length a `GET` would get; `204` and `304` carry no body.
- Hop-by-hop headers are dropped in both directions.
- `GET`, `HEAD` and `OPTIONS` reuse the tunnel's upstream connection and retry
  (up to `idempotent_retries`) on a timeout or a dropped socket. Anything else
  goes out once, on a fresh connection, so a stale socket can't swallow a POST.

## Performance

Measured on a busy M4 Pro (load average around 140) against a loopback upstream
with 2 KB bodies, best of five interleaved rounds; an idle machine will do
better. `bundle exec rake bench` runs the benchmark-ips version:

| | per request |
|---|---|
| Plain proxied request, one per connection | 1.1 ms |
| Requests over one CONNECT tunnel to a TLS upstream | 0.57 ms |

Requests in a tunnel reuse one upstream connection, so a tunnel of 20 requests
opens one upstream TLS connection rather than 20.

**WebMock caveat:** while WebMock's Excon adapter is enabled, it opens a new
connection for every request, including real ones it lets through. Reuse then
doesn't happen; everything still works.

## Configuration

| Option | Default | |
|---|---|---|
| `allowed_host_suffixes` | `[]` | Hosts (and their subdomains) relayed upstream |
| `rewriters` | `[]` | A list, or a callable returning one |
| `on_stop` | `[]` | Callables run with the proxy after it stops |
| `logger` | `nil` | A callable taking a line |
| `host` | `"127.0.0.1"` | Where the proxy listens (always an ephemeral port) |
| `read_timeout`, `connect_timeout`, `write_timeout` | `60`, `30`, `60` | Upstream, in seconds |
| `telemetry_idle_timeout` | `5` | How long a tunnel to a disallowed host may idle |
| `idempotent_retries` | `3` | Attempts for `GET`/`HEAD`/`OPTIONS` |

## Development

```sh
bundle exec rake          # RuboCop and the specs
bundle exec rake e2e      # also the specs that drive real Chrome through the proxy
bundle exec rake bench    # throughput against a loopback upstream
```

The specs are in layers: unit specs for each piece, specs of the proxy over
real sockets against a loopback upstream, integration specs with real VCR and
WebMock, and end-to-end specs in which headless Chrome signs in to a dummy app
through a fake identity provider, records the flow, then replays it with the
provider receiving no requests.

## License

MIT
