# frozen_string_literal: true

require "net/http"
require "uri"
require "openssl"

module Aetheryon
  # Error de transporte (red, DNS, TLS, timeout). Equivale a httpx.RequestError.
  class HttpError < StandardError
    def timeout? = false
  end

  class HttpTimeout < HttpError
    def timeout? = true
  end

  class HttpResponse
    attr_reader :status, :body, :headers

    def initialize(status, body = "", headers = {})
      @status = status
      @body = body.to_s.b
      @headers = headers.transform_keys { |k| k.to_s.downcase }
    end

    def text = @body.dup.force_encoding("UTF-8").scrub
    def json = JSON.parse(text)
    def content = @body
  end

  # Cliente HTTP mínimo (Net::HTTP) con redirecciones. Cualquier objeto con `get` y `post_json` sirve
  # (los tests inyectan uno falso).
  class HttpClient
    MAX_REDIRECTS = 10
    TRANSPORT_ERRORS = [SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError, Net::ProtocolError].freeze

    def initialize(timeout: 20.0, user_agent: "AETHERYON-GamingNewsAPI/1.0")
      @timeout = timeout
      @user_agent = user_agent
    end

    def get(url, params: nil, headers: {}, timeout: nil)
      uri = URI.parse(url)
      if params && !params.empty?
        q = URI.encode_www_form(params)
        uri.query = [uri.query, q].compact.reject(&:empty?).join("&")
      end
      request(Net::HTTP::Get, uri, headers, nil, timeout)
    end

    def post_json(url, payload, headers: {}, timeout: nil)
      request(Net::HTTP::Post, URI.parse(url), headers.merge("Content-Type" => "application/json"), JSON.generate(payload), timeout)
    end

    def close; end

    private

    def request(klass, uri, headers, body, timeout, redirects = 0)
      t = timeout || @timeout
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = http.write_timeout = t
      req = klass.new(uri.request_uri)
      req["User-Agent"] = @user_agent
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      res = http.request(req)
      if res.is_a?(Net::HTTPRedirection) && res["location"] && klass == Net::HTTP::Get
        raise HttpError, "TooManyRedirects" if redirects >= MAX_REDIRECTS

        return request(klass, URI.join(uri.to_s, res["location"]), headers, nil, timeout, redirects + 1)
      end
      HttpResponse.new(res.code.to_i, res.body.to_s, res.each_header.to_h)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise HttpTimeout, "TimeoutException"
    rescue *TRANSPORT_ERRORS => e
      raise HttpError, e.class.name.to_s.split("::").last
    end
  end
end
