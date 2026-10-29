# frozen_string_literal: true

RSpec.describe VcrBrowserProxy::HttpReader do
  subject(:reader) { described_class.new(io) }

  let(:io) { StringIO.new(wire) }

  def wire_of(*lines) = lines.join("\r\n")

  context "with a GET" do
    let(:wire) { wire_of("GET /path?q=1 HTTP/1.1", "Host: example.com", "Accept: */*", "", "") }

    it "reads the method, target and headers, with no body" do
      request = reader.request

      expect(request.to_h).to eq(request_method: "GET", target: "/path?q=1",
                                 headers: { "Host" => "example.com", "Accept" => "*/*" }, body: nil)
    end
  end

  context "with a POST that declares its length" do
    let(:wire) { "#{wire_of("POST /token HTTP/1.1", "Content-Length: 8", "", "")}code=abc" }

    it "reads exactly that many bytes of body" do
      expect(reader.request.body).to eq("code=abc")
    end
  end

  context "with a chunked body and a trailer" do
    let(:wire) do
      "#{wire_of("POST /upload HTTP/1.1", "Transfer-Encoding: chunked", "", "")}" \
        "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Checksum: abc\r\n\r\n"
    end

    it "joins the chunks into one body and skips the trailer" do
      expect(reader.request.body).to eq("hello world")
      expect(reader.request).to be_nil
    end
  end

  context "with a field repeated across lines" do
    let(:wire) { wire_of("GET / HTTP/1.1", "Cookie: a=1", "cookie: b=2", "Accept: text/html", "accept: */*", "", "") }

    it "joins cookies with a semicolon and other fields with a comma, keeping the first spelling" do
      expect(reader.request.headers).to eq("Cookie" => "a=1; b=2", "Accept" => "text/html, */*")
    end
  end

  context "with two requests sent back to back" do
    let(:wire) { wire_of("GET /a HTTP/1.1", "", "GET /b HTTP/1.1", "", "") }

    it "keeps the second in its buffer and reads it next" do
      expect(reader.request.target).to eq("/a")
      expect(reader).to be_buffered
      expect(reader.request.target).to eq("/b")
    end
  end

  context "when the peer closes before sending anything" do
    let(:wire) { "" }

    it "returns nil" do
      expect(reader.request).to be_nil
    end
  end

  context "with a body shorter than its declared length" do
    let(:wire) { "#{wire_of("POST / HTTP/1.1", "Content-Length: 10", "", "")}short" }

    it "refuses it as malformed rather than relaying half a body" do
      expect { reader.request }.to raise_error(described_class::MalformedRequest, /shorter/)
    end
  end

  context "with a bad chunk size" do
    let(:wire) { "#{wire_of("POST / HTTP/1.1", "Transfer-Encoding: chunked", "", "")}zz\r\n" }

    it "refuses it as malformed" do
      expect { reader.request }.to raise_error(described_class::MalformedRequest, /chunk size/)
    end
  end

  context "with a request line missing its target" do
    let(:wire) { wire_of("GET", "", "") }

    it "refuses it as malformed" do
      expect { reader.request }.to raise_error(described_class::MalformedRequest, /request line/)
    end
  end

  context "with a line longer than any real browser sends" do
    let(:wire) { "GET /#{"a" * (described_class::MAX_LINE + 1)}" }

    it "refuses it rather than buffering without bound" do
      expect { reader.request }.to raise_error(described_class::MalformedRequest, /too long/)
    end
  end

  describe "#readable?" do
    it "is true at once when a request is already buffered" do
      reader = described_class.new(StringIO.new(wire_of("GET /a HTTP/1.1", "", "GET /b HTTP/1.1", "", "")))
      reader.request

      expect(reader.readable?(0)).to be(true)
    end

    it "waits on the socket when nothing is buffered" do
      reading, writing = IO.pipe
      reader = described_class.new(reading)

      expect(reader.readable?(0.05)).to be(false)
      writing.write("GET / HTTP/1.1\r\n\r\n")
      expect(reader.readable?(1)).to be(true)
    ensure
      reading&.close
      writing&.close
    end
  end
end
