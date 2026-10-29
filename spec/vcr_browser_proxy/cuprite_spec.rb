# frozen_string_literal: true

require "capybara"
require "capybara/cuprite"

RSpec.describe VcrBrowserProxy::Cuprite do
  let(:proxy) { VcrBrowserProxy.new }

  after { proxy.stop }

  describe ".driver_options" do
    subject(:options) do
      described_class.driver_options(
        proxy, base: { url_blacklist: [/ads/], url_blocklist: [/x/], window_size: [800, 600],
                       browser_options: { "no-sandbox" => nil } }
      )
    end

    it "points Chrome at the proxy" do
      expect(options[:proxy]).to eq(host: "127.0.0.1", port: proxy.port)
    end

    it "trusts exactly the proxy's certificate" do
      expect(options[:browser_options])
        .to include("ignore-certificate-errors-spki-list" => proxy.certificate_spki_sha256)
    end

    it "keeps loopback, where the app under test runs, off the proxy" do
      expect(options[:browser_options]["proxy-bypass-list"]).to eq("127.0.0.1;localhost")
    end

    it "drops Cuprite's URL blocklists, which stall a navigation that has to CONNECT" do
      expect(options).not_to include(:url_blacklist, :url_blocklist)
    end

    it "keeps the caller's other options and Chrome flags" do
      expect(options[:window_size]).to eq([800, 600])
      expect(options[:browser_options]).to include("no-sandbox", "disable-background-networking")
    end
  end

  describe ".register_driver" do
    after do
      Capybara.drivers.delete(:proxy_spec_driver)
      VcrBrowserProxy.current = nil
    end

    it "builds a Cuprite driver aimed at the current proxy when Capybara asks for one" do
      described_class.register_driver(:proxy_spec_driver, base_options: -> { { headless: true } })
      VcrBrowserProxy.current = proxy

      driver = Capybara.drivers[:proxy_spec_driver].call(nil)

      expect(driver).to be_a(Capybara::Cuprite::Driver)
      expect(driver.options[:proxy]).to eq(host: "127.0.0.1", port: proxy.port)
    end

    it "lets a block adjust the final options" do
      described_class.register_driver(:proxy_spec_driver) do |options, current|
        options.merge(browser_options: options[:browser_options].merge("lang" => "en-GB",
                                                                       "x-port" => current.port.to_s))
      end
      VcrBrowserProxy.current = proxy

      driver = Capybara.drivers[:proxy_spec_driver].call(nil)

      expect(driver.options[:browser_options]).to include("lang" => "en-GB", "x-port" => proxy.port.to_s)
    end

    it "explains what's missing when no proxy is current" do
      described_class.register_driver(:proxy_spec_driver)

      expect do
        Capybara.drivers[:proxy_spec_driver].call(nil)
      end.to raise_error(ArgumentError, /VcrBrowserProxy\.current/)
    end
  end

  describe ".retire_sessions" do
    let(:pool) { {} }

    before { allow(Capybara).to receive(:session_pool).and_return(pool) }

    def session(mode, quit: nil)
      instance_double(Capybara::Session, mode: mode).tap do |double|
        quit ? allow(double).to(receive(:quit), &quit) : allow(double).to(receive(:quit))
      end
    end

    it "quits and unpools only the browsers launched against the proxy" do
      proxied = session(:cuprite_vcr_proxy)
      other = session(:cuprite)
      pool.merge!("a" => proxied, "b" => other)

      described_class.retire_sessions.call(proxy)

      expect(proxied).to have_received(:quit)
      expect(other).not_to have_received(:quit)
      expect(pool).to eq("b" => other)
    end

    it "unpools a browser even when quitting it fails, and says so" do
      stuck = session(:cuprite_vcr_proxy, quit: -> { raise "Chrome gone" })
      pool["a"] = stuck

      expect do
        described_class.retire_sessions.call(proxy)
      end.to output(/quit skipped: RuntimeError: Chrome gone/).to_stderr
      expect(pool).to be_empty
    end

    it "hands each retired session, and the ones left, to after_quit" do
      proxied = session(:cuprite_vcr_proxy)
      other = session(:cuprite)
      pool.merge!("a" => proxied, "b" => other)
      seen = []

      described_class.retire_sessions(after_quit: ->(retired, remaining) { seen << [retired, remaining] }).call(proxy)

      expect(seen).to eq([[proxied, [other]]])
    end
  end
end
