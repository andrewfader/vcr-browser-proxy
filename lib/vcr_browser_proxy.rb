# frozen_string_literal: true

require "socket"
require "openssl"
require "uri"
require "excon"
require "rack/utils"

require_relative "vcr_browser_proxy/version"
require_relative "vcr_browser_proxy/configuration"
require_relative "vcr_browser_proxy/exchange"
require_relative "vcr_browser_proxy/http_reader"
require_relative "vcr_browser_proxy/redirect_origin"
require_relative "vcr_browser_proxy/cross_site_cookies"

# A plain-threaded MITM forward proxy for browser-driven tests. Each browser
# request is re-issued through Excon, so a VCR cassette hooked into Excon (and
# WebMock's Excon adapter) sees the browser's HTTPS exactly as it sees the
# server's own calls: one cassette records and replays both.
#
# One self-signed certificate serves every tunnel, so no keypair is generated
# per host, and each connection gets its own thread, so a slow upstream stalls
# only its own connection.
class VcrBrowserProxy
  # RFC 9110 7.6.1: never forwarded between the browser leg and the upstream leg.
  HOP_BY_HOP = %w[
    connection keep-alive proxy-authenticate proxy-authorization
    te trailer transfer-encoding upgrade proxy-connection
  ].freeze

  IDEMPOTENT_METHODS = %w[GET HEAD OPTIONS].freeze

  # A browser dropping an idle tunnel without a TLS close_notify. OpenSSL 3
  # raises where OpenSSL 1 returned EOF; between requests it is routine teardown.
  TEARDOWN_ERRORS = [EOFError, Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError, IOError].freeze

  class << self
    # The proxy a driver factory reads to learn the port to point the browser at.
    attr_accessor :current

    def configuration
      @configuration ||= Configuration.new
    end

    # Defaults every proxy starts from; keyword arguments to .new override them.
    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end

  attr_reader :host, :port, :allowed_host_suffixes

  # allowed_host_suffixes - hosts that are re-issued upstream. Anything else
  #   (browser telemetry, update pings) gets an empty 204 and never reaches Excon.
  # rewriters - objects responding to `request(exchange)` and/or
  #   `response(exchange)`, run in order around the upstream call. Defaults to
  #   the configured rewriter factory, called once per proxy so stateful
  #   rewriters start fresh.
  # on_stop - callables run with the proxy after it stops.
  # telemetry_idle_timeout - how long a tunnel to a disallowed host may sit idle.
  #   Kept short so speculative tunnels don't each park a thread.
  def initialize(**options)
    settings = self.class.configuration.to_options.merge(options)
    unknown = settings.keys - Configuration::OPTIONS
    raise ArgumentError, "unknown option(s): #{unknown.join(", ")}" if unknown.any?

    @allowed_host_suffixes = Array(settings[:allowed_host_suffixes]).map { |suffix| suffix.to_s.downcase }.freeze
    @host = settings[:host]
    @read_timeout = settings[:read_timeout]
    @connect_timeout = settings[:connect_timeout]
    @write_timeout = settings[:write_timeout]
    @telemetry_idle_timeout = settings[:telemetry_idle_timeout]
    @idempotent_retries = settings[:idempotent_retries]
    @rewriters = Array(settings[:rewriters].respond_to?(:call) ? settings[:rewriters].call : settings[:rewriters])
    @on_stop = Array(settings[:on_stop])
    @logger = settings[:logger]
    @server = TCPServer.new(@host, 0)
    @port = @server.addr[1]
    @threads = []
    @threads_mutex = Mutex.new
    @served = []
    @served_mutex = Mutex.new
    @running = false
    @ssl_context = build_ssl_context
  end

  def start
    return self if @running

    @running = true
    server = @server
    @acceptor = Thread.new do
      Thread.current.name = "vcr-proxy-acceptor"
      accept_loop(server)
    end
    self
  end

  def stop
    return self unless @server

    @running = false
    server = @server
    @server = nil
    server.close
    @acceptor&.kill
    @threads_mutex.synchronize do
      @threads.each(&:kill)
      @threads.clear
    end
    @on_stop.each { |hook| hook.call(self) }
    self
  end

  def running?
    @running
  end

  # Starts the proxy, makes it .current for the block, and always stops it.
  def self.open(**)
    proxy = new(**).start
    previous = current
    self.current = proxy
    yield proxy
  ensure
    self.current = previous
    proxy&.stop
  end

  # One hash per request the proxy answered, for assertions and diagnostics.
  def served
    @served_mutex.synchronize { @served.dup }
  end

  # Base64 SHA-256 of the certificate's SubjectPublicKeyInfo: the form Chrome's
  # `--ignore-certificate-errors-spki-list` matches. With the key allowlisted,
  # Chrome skips certificate verification for the tunnel altogether.
  def certificate_spki_sha256
    [OpenSSL::Digest::SHA256.digest(@ssl_context.cert.public_key.public_to_der)].pack("m0")
  end

  def host_allowed?(hostname)
    return false if hostname.nil?

    hostname = hostname.downcase
    @allowed_host_suffixes.any? { |suffix| hostname == suffix || hostname.end_with?(".#{suffix}") }
  end

  private

  def accept_loop(server)
    while @running
      begin
        client = server.accept
      rescue IOError, Errno::EBADF
        break
      rescue SystemCallError
        next
      end

      thread = Thread.new(client) do |socket|
        Thread.current.name = "vcr-proxy-conn"
        handle_connection(socket)
      end
      @threads_mutex.synchronize do
        @threads.select!(&:alive?)
        @threads << thread
      end
    end
  end

  def handle_connection(socket)
    reader = HttpReader.new(socket)
    request = reader.request
    return unless request

    if request.request_method == "CONNECT"
      handle_connect(socket, request.target)
    else
      Upstreams.with { |upstreams| serve(socket, request, URI.parse(request.target), upstreams, keep_alive: false) }
    end
  rescue HttpReader::MalformedRequest, URI::InvalidURIError => e
    reject_malformed(socket, e)
  rescue *TEARDOWN_ERRORS => e
    log "connection closed: #{e.class}"
  rescue StandardError => e
    log "connection error: #{e.class}: #{e.message}"
  ensure
    socket.close unless socket.closed?
  end

  def reject_malformed(io, error)
    log "malformed request: #{error.message}"
    write_response(io, Reply.new(400, { "Content-Type" => "text/plain" }, [], "vcr-browser-proxy: #{error.message}"),
                   keep_alive: false)
  rescue *TEARDOWN_ERRORS
    nil
  end

  # Answer CONNECT, present the static certificate, then serve every request the
  # browser pipelines through the tunnel until it goes idle or closes. Upstream
  # connections opened for the tunnel are reused for its later requests.
  def handle_connect(socket, target)
    connect_host, connect_port = target.split(":", 2)
    allowed = host_allowed?(connect_host)
    log "CONNECT #{target} (allowed=#{allowed})"
    socket.write("HTTP/1.1 200 Connection established\r\n\r\n")
    socket.flush

    ssl = OpenSSL::SSL::SSLSocket.new(socket, @ssl_context)
    ssl.sync_close = true
    begin
      ssl.accept
    rescue OpenSSL::SSL::SSLError, *TEARDOWN_ERRORS => e
      log "TLS accept failed for #{connect_host}: #{e.message}"
      return
    end

    authority = connect_port.nil? || connect_port == "443" ? connect_host : target
    serve_tunnel(ssl, connect_host, authority, allowed ? @read_timeout : @telemetry_idle_timeout)
  ensure
    ssl&.close unless ssl.nil? || ssl.closed?
  end

  def serve_tunnel(ssl, connect_host, authority, idle_timeout)
    reader = HttpReader.new(ssl)
    requests = 0
    Upstreams.with do |upstreams|
      loop do
        unless reader.readable?(idle_timeout)
          log "tunnel idle timeout for #{connect_host} after #{requests} request(s)"
          break
        end

        request = begin
          reader.request
        rescue HttpReader::MalformedRequest => e
          reject_malformed(ssl, e)
          break
        rescue *TEARDOWN_ERRORS
          nil
        end
        unless request
          log "tunnel closed for #{connect_host} after #{requests} request(s)"
          break
        end

        requests += 1
        break unless serve(ssl, request, URI.parse("https://#{authority}#{request.target}"), upstreams,
                           keep_alive: true)
      end
    end
  end

  # Returns whether the connection stays open for the next request.
  def serve(io, request, uri, upstreams, keep_alive:)
    exchange = Exchange.new(request_method: request.request_method, uri: uri, request_headers: request.headers,
                            request_body: request.body)

    if host_allowed?(uri.host)
      write_response(io, relay(exchange, upstreams), head_only: exchange.request_method == "HEAD",
                                                     keep_alive: keep_alive)
    else
      # Keep the tunnel so the browser reuses one handshake for its repeated
      # pings; the short idle timeout bounds the thread.
      record_served(exchange, 204, ignored: true)
      write_response(io, Reply.new(204, {}, [], ""), keep_alive: keep_alive)
    end
    keep_alive
  rescue *TEARDOWN_ERRORS => e
    # The browser went away mid-response; there is no one left to answer.
    log "browser closed during #{log_url(uri)}: #{e.class}"
    false
  rescue StandardError => e
    log "upstream error for #{log_url(uri)}: #{e.class}: #{e.message}"
    record_served(exchange, 502, ignored: false, error: "#{e.class}: #{e.message}") if exchange
    write_response(io, Reply.new(502, { "Content-Type" => "text/plain" }, [], "vcr-browser-proxy upstream error"),
                   keep_alive: false)
    false
  end

  # Runs the rewriters around the upstream call and returns what to send back.
  def relay(exchange, upstreams)
    @rewriters.each { |rewriter| rewriter.request(exchange) if rewriter.respond_to?(:request) }
    response = perform_upstream(exchange, upstreams)
    exchange.status = response.status
    exchange.set_cookies = extract_set_cookies(response)
    exchange.response_headers = response.headers.to_h.reject do |key, _|
      HOP_BY_HOP.include?(key.to_s.downcase) || key.to_s.casecmp?("set-cookie")
    end
    @rewriters.each { |rewriter| rewriter.response(exchange) if rewriter.respond_to?(:response) }

    record_served(exchange, exchange.status, ignored: false)
    location = exchange.response_header("location")
    log "relayed #{exchange.status} #{exchange.request_method} #{log_url(exchange.uri)}" \
        "#{" -> #{log_url(location)}" if location}"
    Reply.new(exchange.status, exchange.response_headers, exchange.set_cookies, response.body.to_s)
  end

  # Idempotent requests reuse the tunnel's upstream connection and retry on a
  # timeout or a dropped socket (a reused connection the server already closed).
  # Anything else goes out once, on a fresh connection.
  def perform_upstream(exchange, upstreams)
    forwarded = exchange.request_headers.reject do |key, _|
      HOP_BY_HOP.include?(key.to_s.downcase) || key.to_s.casecmp?("host")
    end
    idempotent = IDEMPOTENT_METHODS.include?(exchange.request_method)
    attempts = idempotent ? @idempotent_retries : 1
    attempt = 0

    begin
      attempt += 1
      connection = if idempotent
                     upstreams.for(exchange.uri) { |origin| new_connection(origin, persistent: true) }
                   else
                     new_connection(Upstreams.origin(exchange.uri), persistent: false)
                   end
      path = exchange.uri.path.empty? ? "/" : exchange.uri.path
      connection.request(method: exchange.request_method.to_sym, path: path, query: exchange.uri.query,
                         headers: forwarded, body: exchange.request_body)
    rescue Excon::Error::Timeout, Excon::Error::Socket => e
      upstreams.discard(exchange.uri)
      raise if attempt >= attempts

      log "retrying #{exchange.request_method} #{log_url(exchange.uri)} after #{e.class} " \
          "(attempt #{attempt + 1}/#{attempts})"
      sleep(0.5 * attempt) if e.is_a?(Excon::Error::Timeout)
      retry
    end
  end

  def new_connection(origin, persistent:)
    Excon.new(
      origin,
      persistent: persistent,
      read_timeout: @read_timeout,
      connect_timeout: @connect_timeout,
      write_timeout: @write_timeout,
      # The browser follows redirects itself, through this proxy.
      middlewares: Excon.defaults[:middlewares] - [Excon::Middleware::RedirectFollower]
    )
  end

  # A live response carries each Set-Cookie separately in `data[:cookies]`; a
  # response VCR rebuilt from a cassette has only the (possibly joined) header.
  def extract_set_cookies(response)
    cookies = response.data[:cookies] if response.respond_to?(:data)
    return Array(cookies) if cookies && !cookies.empty?

    raw = response.headers["Set-Cookie"] || response.headers["set-cookie"]
    raw ? Array(raw) : []
  end

  Reply = Struct.new(:status, :headers, :set_cookies, :body) do
    def bodiless?
      [204, 304].include?(status.to_i)
    end

    def header(name)
      Array(headers.find { |key, _| key.to_s.casecmp?(name) }&.last).first
    end
  end
  # The proxy frames the browser leg itself.
  FRAMING_HEADERS = %w[content-length transfer-encoding connection].freeze
  private_constant :Reply, :FRAMING_HEADERS

  # head_only: answering a HEAD, whose length describes the body a GET would get.
  def write_response(io, reply, keep_alive:, head_only: false)
    head = "HTTP/1.1 #{reply.status} #{Rack::Utils::HTTP_STATUS_CODES.fetch(reply.status.to_i, "Unknown")}\r\n"
    reply.headers.each do |key, value|
      next if FRAMING_HEADERS.include?(key.to_s.downcase)

      Array(value).each { |line| head << "#{key}: #{line}\r\n" }
    end
    reply.set_cookies.each { |cookie| head << "Set-Cookie: #{cookie}\r\n" }
    head << "Content-Length: #{content_length(reply, head_only)}\r\n" unless reply.bodiless?
    head << "Connection: #{keep_alive ? "keep-alive" : "close"}\r\n\r\n"
    io.write(head)
    io.write(reply.body) unless head_only || reply.bodiless?
    io.flush
  end

  def content_length(reply, head_only)
    (head_only && reply.header("content-length")) || reply.body.bytesize
  end

  def record_served(exchange, status, ignored:, error: nil)
    entry = {
      host: exchange.uri.host,
      method: exchange.request_method,
      status: status,
      url: exchange.uri.to_s,
      ignored: ignored,
      error: error,
      auth: exchange.auth_scheme,
      cookie_names: exchange.request_cookie_names,
      sec_fetch_dest: exchange.request_header("sec-fetch-dest").to_s,
      sec_fetch_site: exchange.request_header("sec-fetch-site").to_s,
      referer: exchange.request_header("referer").to_s
    }
    @served_mutex.synchronize { @served << entry }
  end

  # One certificate for every tunnel keeps RSA keygen off the request path.
  def build_ssl_context
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    name = OpenSSL::X509::Name.parse("/CN=vcr-browser-proxy")
    cert.subject = name
    cert.issuer = name
    cert.public_key = key.public_key
    # A wide window, so a frozen test clock never lands outside it.
    cert.not_before = Time.at(0).utc
    cert.not_after = Time.at(0).utc + (100 * 365 * 24 * 60 * 60)
    cert.sign(key, OpenSSL::Digest.new("SHA256"))

    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    # The reader speaks HTTP/1.1 only; a browser that negotiated h2 over the
    # tunnel would send frames no request line can be read from.
    context.alpn_select_cb = ->(_protocols) { "http/1.1" }
    context
  end

  # Query strings can carry codes and tokens, so logs show the path only.
  def log_url(url)
    uri = url.is_a?(URI) ? url : URI.parse(url.to_s)
    "#{uri.scheme}://#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    "(unparseable URL)"
  end

  def log(message)
    @logger&.call("[vcr-proxy] #{message}")
  end

  # Upstream Excon connections for one browser connection, keyed by origin.
  # Excon connections are not thread-safe, and a browser connection is served
  # by one thread, so the pool lives exactly as long as that thread's loop.
  class Upstreams
    def self.with
      upstreams = new
      yield upstreams
    ensure
      upstreams&.close
    end

    def initialize
      @connections = {}
    end

    def self.origin(uri)
      "#{uri.scheme}://#{uri.host}:#{uri.port}"
    end

    def for(uri)
      origin = self.class.origin(uri)
      @connections[origin] ||= yield(origin)
    end

    def discard(uri)
      @connections.delete(self.class.origin(uri))&.reset
    end

    def close
      @connections.each_value(&:reset)
      @connections.clear
    end
  end
  private_constant :Upstreams
end
