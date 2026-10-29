# Changelog

## 0.1.0 

First release

- Threaded MITM proxy that re-issues browser requests through Excon, so VCR and
  WebMock see them.
- One certificate for every host, with its SPKI for Chrome's allowlist.
- Host allowlist; everything else gets an empty 204.
- Upstream connection reuse within a tunnel for idempotent requests, with
  retries on timeouts and dropped sockets.
- Chunked request bodies, `HEAD`, bodiless statuses, and a 400 for malformed
  requests.
- `RedirectOrigin` and `CrossSiteCookies` rewriters.
- `VcrBrowserProxy.configure`, `VcrBrowserProxy.open`, the `:vcr_browser_proxy`
  RSpec tag, and Cuprite helpers (`register_driver`, `driver_options`,
  `retire_sessions`).
