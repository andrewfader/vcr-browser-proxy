# frozen_string_literal: true

class VcrBrowserProxy
  # Defaults for every proxy, set once in a support file:
  #
  #   VcrBrowserProxy.configure do |config|
  #     config.allowed_host_suffixes = %w[okta.com oktacdn.com]
  #     config.rewriters = -> { [VcrBrowserProxy::RedirectOrigin.new(registered_origin: "http://localhost:3000")] }
  #     config.on_stop << ->(proxy) { warn proxy.served.inspect }
  #   end
  #
  # `rewriters` may be a list or a callable returning one. Use a callable when a
  # rewriter keeps state, so each proxy gets its own.
  class Configuration
    OPTIONS = %i[
      allowed_host_suffixes host read_timeout connect_timeout write_timeout
      telemetry_idle_timeout idempotent_retries rewriters on_stop logger
    ].freeze

    attr_accessor(*OPTIONS)

    def initialize
      @allowed_host_suffixes = []
      @host = "127.0.0.1"
      @read_timeout = 60
      @connect_timeout = 30
      @write_timeout = 60
      @telemetry_idle_timeout = 5
      @idempotent_retries = 3
      @rewriters = []
      @on_stop = []
      @logger = nil
    end

    def to_options
      OPTIONS.to_h { |name| [name, public_send(name)] }
    end
  end
end
