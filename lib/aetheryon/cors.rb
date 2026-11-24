# frozen_string_literal: true

module Aetheryon
  # CORS equivalente a CORSMiddleware de Starlette (solo se monta si CORS_ORIGINS tiene valores).
  class Cors
    METHODS = %w[GET POST PATCH DELETE].freeze
    ALLOW_HEADERS = %w[Accept Accept-Language Content-Language Content-Type X-API-Key].freeze

    def initialize(app, origins)
      @app = app
      @origins = origins
      @any = origins.include?("*")
    end

    def call(env)
      origin = env["HTTP_ORIGIN"]
      return @app.call(env) if origin.nil?

      if env["REQUEST_METHOD"] == "OPTIONS" && env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"]
        return preflight(env, origin)
      end

      status, headers, body = @app.call(env)
      if @any || @origins.include?(origin)
        headers = headers.dup
        headers["access-control-allow-origin"] = @any ? "*" : origin
        headers["vary"] = [headers["vary"], "Origin"].compact.join(", ") unless @any
      end
      [status, headers, body]
    end

    private

    def preflight(env, origin)
      h = {
        "access-control-allow-methods" => METHODS.join(", "),
        "access-control-max-age" => "600",
        "access-control-allow-headers" => ALLOW_HEADERS.join(", ")
      }
      h["access-control-allow-origin"] = @any ? "*" : origin if @any || @origins.include?(origin)
      h["vary"] = "Origin" unless @any
      errors = []
      errors << "origin" unless @any || @origins.include?(origin)
      errors << "method" unless METHODS.include?(env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"])
      req_headers = env["HTTP_ACCESS_CONTROL_REQUEST_HEADERS"]
      if req_headers
        allowed = ALLOW_HEADERS.map(&:downcase)
        errors << "headers" unless req_headers.split(",").map { |x| x.strip.downcase }.reject(&:empty?).all? { |x| allowed.include?(x) }
      end
      if errors.empty?
        [200, h.merge("content-type" => "text/plain; charset=utf-8", "content-length" => "2"), ["OK"]]
      else
        msg = "Disallowed CORS #{errors.join(', ')}"
        [400, h.merge("content-type" => "text/plain; charset=utf-8", "content-length" => msg.bytesize.to_s), [msg]]
      end
    end
  end
end
