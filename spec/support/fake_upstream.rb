# frozen_string_literal: true

require "socket"
require "openssl"

# An HTTP/1.1 server on loopback that the proxy's Excon calls really reach, so
# VCR can record them. It keeps connections alive and counts them, so a spec
# can tell whether the proxy reused one.
#
#   upstream = FakeUpstream.new { |request| [200, { "Content-Type" => "text/plain" }, "hi"] }
#   upstream.url("/path")  # => "http://127.0.0.1:54321/path"
class FakeUpstream
  Request = Struct.new(:request_method, :path, :headers, :body) do
    def header(name)
      headers[name.downcase]
    end
  end

  attr_reader :port, :requests

  # drop_idle: close each connection right after its response without saying
  # so, as a server does when its keep-alive timeout passes.
  def initialize(tls: false, drop_idle: false, &responder)
    @responder = responder
    @tls = tls
    @drop_idle = drop_idle
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @connections = 0
    @mutex = Mutex.new
    @threads = []
    @acceptor = Thread.new { accept_loop }
  end

  def url(path = "/")
    "#{@tls ? "https" : "http"}://127.0.0.1:#{@port}#{path}"
  end

  def connections
    @mutex.synchronize { @connections }
  end

  def stop
    @acceptor.kill
    @threads.each(&:kill)
    @server.close unless @server.closed?
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @mutex.synchronize { @connections += 1 }
      @threads << Thread.new(socket) { |client| serve(client) }
    end
  rescue IOError
    nil
  end

  def serve(socket)
    socket = wrap_tls(socket) if @tls
    while (request = read_request(socket))
      @requests << request
      status, headers, body = @responder.call(request)
      write(socket, status, headers, body.to_s)
      break if @drop_idle || request.header("connection").to_s.casecmp?("close")
    end
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    line = socket.gets
    return nil if line.nil?

    method, path, = line.split(" ", 3)
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      key, value = header.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    Request.new(method, path, headers, length.positive? ? socket.read(length) : nil)
  end

  def write(socket, status, headers, body)
    socket.write("HTTP/1.1 #{status} Fake\r\n")
    headers.each { |key, value| Array(value).each { |v| socket.write("#{key}: #{v}\r\n") } }
    socket.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    socket.flush
  end

  def wrap_tls(socket)
    ssl = OpenSSL::SSL::SSLSocket.new(socket, self.class.tls_context)
    ssl.sync_close = true
    ssl.accept
    ssl
  end

  class << self
    def tls_context
      @tls_context ||= begin
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        OpenSSL::SSL::SSLContext.new.tap do |context|
          context.cert = cert
          context.key = key
        end
      end
    end
  end
end
