# frozen_string_literal: true

class VcrBrowserProxy
  # OAuth providers redirect to the one callback origin registered with them
  # (say http://localhost:3000), while Capybara serves the app on an ephemeral
  # port. This rewrites redirects to the registered origin onto the port the
  # browser is actually using, read from the requests' Origin/Referer.
  class RedirectOrigin
    def initialize(registered_origin:)
      @registered_origin = registered_origin.to_s.chomp("/")
      @active_origin = nil
      @mutex = Mutex.new
    end

    def request(exchange)
      origin = local_origin(exchange.request_origin)
      @mutex.synchronize { @active_origin = origin } if origin
    end

    def response(exchange)
      active = @mutex.synchronize { @active_origin }
      return if active.nil? || active == @registered_origin

      exchange.rewrite_location do |location|
        location.start_with?(@registered_origin) ? location.sub(@registered_origin, active) : location
      end
    end

    private

    def local_origin(origin)
      return nil if origin.nil?

      uri = URI.parse(origin)
      "#{uri.scheme}://#{uri.host}:#{uri.port}" if uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host)
    rescue URI::InvalidURIError
      nil
    end
  end
end
