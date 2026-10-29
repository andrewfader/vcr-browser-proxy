# frozen_string_literal: true

require "net/http"

# What a browser does on the wire, without a browser: plain proxied HTTP, or a
# CONNECT tunnel carrying TLS.
module BrowserClient
  def via_proxy(url, method: :get, body: nil, headers: {}, proxy: self.proxy)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port)
    if uri.scheme == "https"
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    http.start { |session| session.send_request(method.to_s.upcase, uri.request_uri, body, headers) }
  end

  # Several requests over one CONNECT tunnel, the way Chrome reuses a tunnel.
  def over_one_tunnel(host, paths, proxy: self.proxy)
    http = Net::HTTP.new(host, 443, proxy.host, proxy.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.start { |session| paths.map { |path| session.get(path) } }
  end

  # A raw CONNECT, returning the TLS socket so a spec can inspect the handshake.
  def open_tunnel(host, proxy: self.proxy, alpn: %w[h2 http/1.1])
    socket = TCPSocket.new(proxy.host, proxy.port)
    socket.write("CONNECT #{host}:443 HTTP/1.1\r\nHost: #{host}:443\r\n\r\n")
    status = socket.gets
    socket.gets
    context = OpenSSL::SSL::SSLContext.new
    context.alpn_protocols = alpn
    ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
    ssl.hostname = host
    ssl.sync_close = true
    ssl.connect
    [status, ssl]
  end
end
