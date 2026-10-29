# frozen_string_literal: true

require "timeout"
require "vcr_browser_proxy"

class VcrBrowserProxy
  # Cuprite options that route Chrome through a proxy, and a driver that reads
  # VcrBrowserProxy.current when Capybara opens its session.
  module Cuprite
    DRIVER_NAME = :cuprite_vcr_proxy

    # Background traffic Chrome would otherwise tunnel through the proxy, one
    # thread per tunnel.
    QUIET_BACKGROUND_FLAGS = {
      "disable-background-networking" => nil,
      "disable-default-apps" => nil,
      "disable-component-update" => nil,
      "disable-domain-reliability" => nil,
      "disable-sync" => nil,
      "metrics-recording-only" => nil,
      "no-first-run" => nil
    }.freeze

    module_function

    # Drops `url_blacklist`/`url_blocklist`: Ferrum implements them with
    # `Fetch.enable` on every URL, and a paused navigation that has to CONNECT
    # through an upstream proxy never does.
    def driver_options(proxy, base: {})
      options = base.except(:url_blacklist, :url_blocklist)
      options.merge(
        proxy: { host: proxy.host, port: proxy.port },
        browser_options: (base[:browser_options] || {}).merge(browser_flags(proxy))
      )
    end

    # `ignore-certificate-errors-spki-list` is honoured only alongside
    # `--user-data-dir`, which Ferrum always passes.
    def browser_flags(proxy)
      {
        "ignore-certificate-errors" => nil,
        "ignore-certificate-errors-spki-list" => proxy.certificate_spki_sha256,
        "proxy-bypass-list" => "127.0.0.1;localhost"
      }.merge(QUIET_BACKGROUND_FLAGS)
    end

    # Registers a Capybara driver for VcrBrowserProxy.current. `base_options`
    # is a hash, or a callable returning one, of your usual Cuprite options;
    # pass a block to adjust the final options (say, to add Chrome flags).
    def register_driver(name = DRIVER_NAME, base_options: {}, &customize)
      require "capybara/cuprite"
      ::Capybara.register_driver(name) do |app|
        proxy = VcrBrowserProxy.current
        raise ArgumentError, "start a VcrBrowserProxy and set VcrBrowserProxy.current before using #{name}" unless proxy

        base = base_options.respond_to?(:call) ? base_options.call : base_options
        options = driver_options(proxy, base: base)
        options = yield(options, proxy) if customize
        ::Capybara::Cuprite::Driver.new(app, **options)
      end
    end

    # An on_stop hook. Chrome takes the proxy's port at launch and Capybara
    # pools sessions across examples, so a browser that outlives its proxy
    # would send the next example to a dead port. Quits and unpools every
    # session using `driver_name`, then calls `after_quit` with each session and
    # the sessions still pooled.
    def retire_sessions(driver_name = DRIVER_NAME, quit_timeout: 10, after_quit: nil)
      lambda do |_proxy|
        pool = ::Capybara.send(:session_pool)
        retired = pool.select { |_key, session| session.mode == driver_name }
        retired.each do |key, session|
          begin
            Timeout.timeout(quit_timeout) { session.quit }
          rescue StandardError => e
            warn "[vcr-proxy] pooled browser quit skipped: #{e.class}: #{e.message}"
          end
          pool.delete(key)
          after_quit&.call(session, pool.values)
        end
      end
    end
  end
end
