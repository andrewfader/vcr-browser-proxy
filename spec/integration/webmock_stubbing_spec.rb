# frozen_string_literal: true

RSpec.describe "Stubbing browser traffic with WebMock" do
  before do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  # Leave WebMock off again: its Excon adapter opens a new connection per
  # request even for allowed real requests, which would hide connection reuse
  # from the specs that measure it.
  after do
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  it "lets a plain stub_request answer the browser, since the proxy calls through Excon" do
    extend WebMock::API

    stub_request(:get, "https://account.example.com/oauth/authorize?client_id=1")
      .to_return(status: 302, headers: { "Location" => "http://localhost:3000/callback?code=stubbed" })
    proxy = VcrBrowserProxy.new(allowed_host_suffixes: %w[example.com]).start

    response = over_one_tunnel("account.example.com", %w[/oauth/authorize?client_id=1], proxy: proxy).first

    expect(response.code).to eq("302")
    expect(response["Location"]).to eq("http://localhost:3000/callback?code=stubbed")
  ensure
    proxy&.stop
  end
end
