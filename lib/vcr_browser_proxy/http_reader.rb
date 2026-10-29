# frozen_string_literal: true

class VcrBrowserProxy
  # Reads HTTP/1.1 requests off a socket through its own buffer, so a request
  # the browser sent right behind another is never stranded in a buffer that a
  # readability check on the socket can't see.
  class HttpReader
    Request = Struct.new(:request_method, :target, :headers, :body)

    CHUNK = 16 * 1024
    MAX_LINE = 64 * 1024

    class MalformedRequest < StandardError; end

    def initialize(io)
      @io = io
      @buffer = +""
      @eof = false
    end

    def buffered?
      !@buffer.empty? || (@io.respond_to?(:pending) && @io.pending.positive?)
    end

    def readable?(timeout)
      buffered? || !@io.to_io.wait_readable(timeout).nil?
    end

    # nil when the peer closed before sending a request line.
    def request
      line = read_line
      return nil if line.nil?

      method, target, = line.split(" ", 3)
      raise MalformedRequest, "bad request line" if method.nil? || target.nil?

      headers = read_headers
      Request.new(method.upcase, target, headers, read_body(headers))
    end

    private

    def read_headers
      headers = {}
      while (line = read_line)
        break if line.empty?

        key, value = line.split(":", 2)
        next unless value

        add_header(headers, key.strip, value.strip)
      end
      headers
    end

    # Repeated fields join with a comma (RFC 9110 5.3), Cookie with "; ".
    def add_header(headers, key, value)
      existing = headers.keys.find { |name| name.casecmp?(key) }
      if existing
        separator = key.casecmp?("cookie") ? "; " : ", "
        headers[existing] = "#{headers[existing]}#{separator}#{value}"
      else
        headers[key] = value
      end
    end

    def read_body(headers)
      if header(headers, "transfer-encoding").to_s.downcase.include?("chunked")
        read_chunked
      else
        length = header(headers, "content-length").to_i
        length.positive? ? read_exactly(length) : nil
      end
    end

    def read_chunked
      body = +""
      while (size = chunk_size(read_line)).positive?
        body << read_exactly(size)
        read_line
      end
      skip_trailers
      body
    end

    def chunk_size(line)
      raise MalformedRequest, "truncated chunked body" if line.nil?

      Integer(line.split(";", 2).first.strip, 16)
    rescue ArgumentError
      raise MalformedRequest, "bad chunk size"
    end

    def skip_trailers
      line = read_line
      line = read_line while line && !line.empty?
    end

    def header(headers, name)
      headers.find { |key, _| key.casecmp?(name) }&.last
    end

    def read_line
      index = @buffer.index("\n")
      while index.nil?
        raise MalformedRequest, "line too long" if @buffer.bytesize > MAX_LINE
        return take_rest unless fill

        index = @buffer.index("\n")
      end
      @buffer.slice!(0..index).chomp
    end

    def take_rest
      @buffer.empty? ? nil : @buffer.slice!(0..).chomp
    end

    def read_exactly(length)
      fill while @buffer.bytesize < length && !@eof
      raise MalformedRequest, "body shorter than its length" if @buffer.bytesize < length

      @buffer.slice!(0, length)
    end

    def fill
      return false if @eof

      @buffer << @io.readpartial(CHUNK)
      true
    rescue EOFError
      @eof = true
      false
    end
  end
end
