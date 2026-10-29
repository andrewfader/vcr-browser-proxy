# frozen_string_literal: true

class VcrBrowserProxy
  # A test app on http://localhost is cross-site to every provider it signs in
  # through, so cookies a provider sets as SameSite=Lax would not be sent back on
  # its own redirects. This re-marks relayed cookies `SameSite=None; Secure`
  # (valid, since every proxied host is reached over the proxy's TLS tunnel).
  #
  # Cookies set in a third-party iframe are left alone, so a flow that depends
  # on iframe cookies fails here the way it would in a real browser.
  class CrossSiteCookies
    def response(exchange)
      return if third_party_iframe?(exchange)

      exchange.set_cookies = exchange.set_cookies.map { |cookie| self.class.cross_site(cookie) }
    end

    def self.cross_site(cookie)
      upgraded = "#{cookie.to_s.sub(/;\s*SameSite=(Lax|Strict|None)/i, "")}; SameSite=None"
      upgraded.match?(/;\s*Secure/i) ? upgraded : "#{upgraded}; Secure"
    end

    private

    def third_party_iframe?(exchange)
      return false unless exchange.request_header("sec-fetch-dest").to_s.casecmp?("iframe")

      origin = exchange.request_origin
      return false if origin.nil?

      registrable_domain(URI.parse(origin).host) != registrable_domain(exchange.uri.host)
    rescue URI::InvalidURIError
      false
    end

    # Last two labels: enough for the .com/.net hosts this is used against, not a
    # public-suffix-list lookup.
    def registrable_domain(hostname)
      hostname.to_s.downcase.split(".").last(2).join(".")
    end
  end
end
