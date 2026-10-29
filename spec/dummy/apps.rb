# frozen_string_literal: true

require "rack"
require "rack/request"
require "uri"

# Two small Rack apps for the browser specs.
module Dummy
  REGISTERED_CALLBACK = "http://localhost:3000/callback"

  def self.html(title, body)
    # Avoid a timing-dependent /favicon.ico request appearing only on replay.
    head = %(<title>#{title}</title><link rel="icon" href="data:,">)
    [200, { "content-type" => "text/html; charset=utf-8" },
     ["<!doctype html><html><head>#{head}</head><body>#{body}</body></html>"]]
  end

  # The app under test. Capybara serves it on loopback, which Chrome reaches
  # directly; it signs users in through the provider at https://provider.test.
  class RelyingParty
    def call(env)
      request = Rack::Request.new(env)
      case request.path
      when "/"
        authorize = "https://provider.test/authorize?#{URI.encode_www_form(redirect_uri: REGISTERED_CALLBACK,
                                                                           state: "s1")}"
        Dummy.html("Home", %(<a id="sign-in" href="#{authorize}">Sign in with Provider</a>))
      when "/callback"
        Dummy.html("Signed in", "<p id='greeting'>Signed in as #{Rack::Utils.escape_html(request.params["user"])} " \
                                "(state #{Rack::Utils.escape_html(request.params["state"])})</p>")
      else
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end
    end
  end

  # A third-party identity provider. It sets a session cookie on its sign-in
  # page and refuses to issue a redirect without it, loads a script the way a
  # real login widget would, and redirects to the callback registered with it.
  class Provider
    attr_reader :hits

    def initialize
      @hits = 0
    end

    def call(env)
      @hits += 1
      request = Rack::Request.new(env)
      case [request.request_method, request.path]
      in ["GET", "/authorize"] then sign_in_page(request)
      in ["GET", "/widget.js"]
        [200, { "content-type" => "application/javascript" },
         ["document.getElementById('widget').textContent = 'Widget loaded';"]]
      in ["POST", "/session"] then create_session(request)
      else [404, { "content-type" => "text/plain" }, ["not found"]]
      end
    end

    private

    def sign_in_page(request)
      status, headers, body = Dummy.html("Provider sign-in", <<~HTML)
        <form method="post" action="/session">
          <label>Username <input name="user"></label>
          <input type="hidden" name="redirect_uri" value="#{Rack::Utils.escape_html(request.params["redirect_uri"])}">
          <input type="hidden" name="state" value="#{Rack::Utils.escape_html(request.params["state"])}">
          <button>Continue</button>
        </form>
        <div id="widget">Widget not loaded</div>
        <script src="/widget.js"></script>
      HTML
      [status, headers.merge("set-cookie" => "provider_session=abc123; Path=/; SameSite=Lax"), body]
    end

    def create_session(request)
      unless request.cookies["provider_session"] == "abc123"
        return [403, { "content-type" => "text/plain" }, ["no provider session cookie"]]
      end

      callback = "#{request.params["redirect_uri"]}?" +
                 URI.encode_www_form(user: request.params["user"], state: request.params["state"])
      [302, { "location" => callback }, []]
    end
  end
end
