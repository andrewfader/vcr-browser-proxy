# frozen_string_literal: true

class VcrBrowserProxy
  # One browser request and the response relayed for it. Rewriters may replace
  # `uri` before the upstream call and edit the response fields after it.
  class Exchange
    attr_accessor :request_method, :uri, :request_headers, :request_body,
                  :status, :response_headers, :set_cookies

    def initialize(request_method:, uri:, request_headers:, request_body: nil)
      @request_method = request_method
      @uri = uri
      @request_headers = request_headers
      @request_body = request_body
      @response_headers = {}
      @set_cookies = []
    end

    def request_header(name)
      header(request_headers, name)
    end

    def response_header(name)
      Array(header(response_headers, name)).first
    end

    # Applies the block to every Location value and keeps the header's shape.
    def rewrite_location
      response_headers.each_key do |key|
        next unless key.to_s.casecmp?("location")

        values = Array(response_headers[key]).map { |location| yield location.to_s }
        response_headers[key] = values.one? ? values.first : values
      end
    end

    # :none, :basic or :other, from the browser's Authorization header.
    def auth_scheme
      value = request_header("authorization").to_s
      return :none if value.empty?
      return :basic if value.downcase.start_with?("basic ")

      :other
    end

    def request_cookie_names
      request_header("cookie").to_s.split(";").filter_map do |pair|
        name = pair.split("=", 2).first.to_s.strip
        name unless name.empty?
      end
    end

    # The page that issued the request, from Origin, falling back to Referer:
    # headless Chrome sends some CORS GETs with a Referer and no Origin.
    def request_origin
      origin = request_header("origin").to_s
      return origin unless origin.empty? || origin == "null"

      referer = URI.parse(request_header("referer").to_s)
      return nil unless %w[http https].include?(referer.scheme) && referer.host

      port = referer.port == referer.default_port ? "" : ":#{referer.port}"
      "#{referer.scheme}://#{referer.host}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    private

    def header(headers, name)
      headers.find { |key, _| key.to_s.casecmp?(name) }&.last
    end
  end
end
