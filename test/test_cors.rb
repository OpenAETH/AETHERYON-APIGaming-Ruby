# frozen_string_literal: true

require_relative "test_helper"

class TestCors < Minitest::Test
  include PgTest

  def app = Application.new(settings.with(cors_origins: ["http://front.test"]), client: fake_client { http_resp(503) })

  def test_simple_and_preflight
    c = Client.new(app)
    r = c.request(:get, "/health", headers: { "Origin" => "http://front.test" })
    assert_equal 200, r.status
    pre = c.request(:options, "/api/news", headers: { "Origin" => "http://front.test", "Access-Control-Request-Method" => "POST",
                                                      "Access-Control-Request-Headers" => "x-api-key, content-type" })
    assert_equal 200, pre.status
    bad = c.request(:options, "/api/news", headers: { "Origin" => "http://evil.test", "Access-Control-Request-Method" => "GET" })
    assert_equal 400, bad.status
    assert_includes bad.body, "Disallowed CORS origin"
  end

  def test_headers_present
    s = Rack::MockRequest.new(app).get("/health", "HTTP_ORIGIN" => "http://front.test")
    assert_equal "http://front.test", s.headers["access-control-allow-origin"]
    assert_equal "Origin", s.headers["vary"]
    none = Rack::MockRequest.new(app).get("/health", "HTTP_ORIGIN" => "http://evil.test")
    assert_nil none.headers["access-control-allow-origin"]
  end
end
