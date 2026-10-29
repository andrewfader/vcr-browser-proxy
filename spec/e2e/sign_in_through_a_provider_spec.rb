# frozen_string_literal: true

require "tmpdir"
require "capybara/rspec"
require "capybara/cuprite"
require_relative "../dummy/apps"

# Real headless Chrome, a real Capybara server, and a provider that really
# answers while recording, then is shut down for the replay.
RSpec.describe "Signing in through a third-party provider", :e2e, type: :feature do
  include Capybara::DSL

  around do |example|
    Dir.mktmpdir do |dir|
      VCR.configure do |c|
        c.cassette_library_dir = dir
        c.hook_into :excon
        c.allow_http_connections_when_no_cassette = true
      end
      @cassette_dir = dir
      example.run
    end
  end

  before do
    Capybara.server = :puma, { Silent: true }
    Capybara.app = Dummy::RelyingParty.new
    options = {
      headless: true, window_size: [1024, 768], timeout: 15, process_timeout: 30,
      # Hosted runners cannot always provide Chrome's OS sandbox. These tests
      # only visit the local dummy app and provider; keep this out of gem defaults.
      browser_options: ENV["GITHUB_ACTIONS"] == "true" ? { "no-sandbox" => nil } : {},
      logger: ENV["GITHUB_ACTIONS"] == "true" ? $stderr : nil
    }
    VcrBrowserProxy::Cuprite.register_driver(base_options: options)
  end

  let(:provider) { Dummy::Provider.new }
  let(:provider_server) { Capybara::Server.new(provider).boot }
  let(:provider_origin) { "http://#{provider_server.host}:#{provider_server.port}" }

  # Chrome asks for https://provider.test; the proxy sends that to the loopback
  # provider. Swap this for nothing when the provider is real.
  let(:provider_resolver) do
    origin = provider_origin
    Class.new do
      define_method(:request) do |exchange|
        exchange.uri = URI("#{origin}#{exchange.uri.request_uri}") if exchange.uri.host == "provider.test"
      end
    end.new
  end

  def with_proxy(&)
    VcrBrowserProxy.open(
      allowed_host_suffixes: %w[provider.test],
      rewriters: [provider_resolver,
                  VcrBrowserProxy::RedirectOrigin.new(registered_origin: "http://localhost:3000"),
                  VcrBrowserProxy::CrossSiteCookies.new],
      on_stop: [VcrBrowserProxy::Cuprite.retire_sessions]
    ) do |proxy|
      Capybara.current_driver = VcrBrowserProxy::Cuprite::DRIVER_NAME
      yield(proxy)
    ensure
      Capybara.use_default_driver
    end
  end

  def sign_in_as(user)
    visit "/"
    click_on "Sign in with Provider"
    expect(page).to have_title("Provider sign-in")
    expect(page).to have_css("#widget", text: "Widget loaded")
    fill_in "Username", with: user
    click_on "Continue"
    expect(page).to have_css("#greeting", text: "Signed in as #{user} (state s1)")
  end

  def cassette_text(name) = File.read(File.join(@cassette_dir, "#{name}.yml"))

  it "records the provider's pages, script and form post into the example's cassette" do
    with_proxy do |proxy|
      VCR.use_cassette("sign_in", record: :once) { sign_in_as("ada") }

      relayed = proxy.served.reject { |entry| entry[:ignored] }.map { |entry| [entry[:method], URI(entry[:url]).path] }
      expect(relayed).to include(%w[GET /authorize], %w[GET /widget.js], %w[POST /session])
    end

    expect(cassette_text("sign_in")).to include("/authorize", "/widget.js", "/session")
  end

  it "replays the whole sign-in without asking the provider for anything" do
    with_proxy { VCR.use_cassette("replay", record: :once) { sign_in_as("grace") } }
    hits_while_recording = provider.hits

    with_proxy do |proxy|
      VCR.use_cassette("replay", record: :none) { sign_in_as("grace") }

      expect(proxy.served.select { |entry| entry[:error] }).to be_empty
    end
    expect(hits_while_recording).to be >= 3
    expect(provider.hits).to eq(hits_while_recording)
  end

  it "carries the provider's SameSite=Lax session cookie back on its own form post" do
    with_proxy do |proxy|
      VCR.use_cassette("cookie", record: :once) { sign_in_as("lin") }

      post = proxy.served.find { |entry| entry[:method] == "POST" && URI(entry[:url]).path == "/session" }
      expect(post[:cookie_names]).to include("provider_session")
    end
  end

  it "lands back on the app's own port, not the callback port registered with the provider" do
    with_proxy do
      VCR.use_cassette("port", record: :once) { sign_in_as("kay") }

      expect(URI(page.current_url).port).to eq(Capybara.current_session.server.port)
    end
  end

  it "keeps Chrome's background traffic out of the cassette" do
    with_proxy do |proxy|
      VCR.use_cassette("telemetry", record: :once) do
        sign_in_as("bo")
        page.execute_script("fetch('https://update.googleapis.com/service/update2').catch(() => {})")
        Timeout.timeout(5) { sleep 0.05 until proxy.served.any? { |entry| entry[:ignored] } }
      end
    end

    expect(cassette_text("telemetry")).not_to include("googleapis")
  end

  it "retires the browser when the proxy stops, so the next proxy gets a Chrome aimed at its own port" do
    first_browser = nil
    with_proxy do
      VCR.use_cassette("first", record: :once) { sign_in_as("one") }
      first_browser = Capybara.current_session.driver.browser
    end

    with_proxy do
      VCR.use_cassette("second", record: :once) { sign_in_as("two") }

      expect(Capybara.current_session.driver.browser).not_to equal(first_browser)
    end
  end
end
