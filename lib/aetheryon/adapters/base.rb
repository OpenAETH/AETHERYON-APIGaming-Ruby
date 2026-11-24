# frozen_string_literal: true

module Aetheryon
  # Fallo de la fuente (red, formato, validación). Afecta solo a esa fuente.
  class AdapterError < StandardError; end

  # La fuente no puede operar ahora (sin credenciales, licencia, cuota). No es un error de ejecución.
  class SourceUnavailable < StandardError
    def status = "blocked"
  end

  class QuotaExceeded < SourceUnavailable
    def status = "quota_exhausted"
  end

  AdapterContext = Struct.new(:client, :db, :settings, :quota, :force)
  FetchResult = Struct.new(:items, :requests_made, :warnings) do
    def initialize(items: [], requests_made: 0, warnings: []) = super(items, requests_made, warnings)
  end

  # Contrato común de adaptadores. Agregar una fuente = una subclase + registrarla en registry.rb.
  class SourceAdapter
    attr_reader :key, :name, :kind, :url

    def min_interval_min(settings) = settings.rss_min_interval_min

    # Motivo si la fuente no puede usarse (credenciales, licencia); nil si está disponible.
    def availability(_settings) = nil

    def fetch(_ctx) = raise(NotImplementedError)
  end

  module Http
    module_function

    # GET con caché persistente + validadores HTTP (ETag/Last-Modified). Devuelve [cuerpo, desde_cache].
    # `before_request` solo se ejecuta si hay que ir a la red (p. ej. para consumir cuota). Los errores se
    # re-lanzan como AdapterError SIN incluir la URL (puede contener credenciales).
    def cached_get(ctx, cache_key, url, params: nil, headers: nil, ttl_s: 0, max_bytes: 5_000_000, before_request: nil)
      row = ctx.db.cache_get(cache_key)
      return [row["body"].b, true] if row && !ctx.force && (Time.now.to_f - row["fetched_ts"]) < ttl_s

      h = (headers || {}).dup
      if row
        h["If-None-Match"] = row["etag"] if row["etag"]
        h["If-Modified-Since"] = row["last_modified"] if row["last_modified"]
      end
      before_request&.call
      host = begin
        URI.parse(url).host
      rescue URI::InvalidURIError
        "?"
      end
      begin
        r = ctx.client.get(url, params: params, headers: h)
      rescue HttpError => e
        raise AdapterError, "#{e.message} al contactar #{host}"
      end
      if r.status == 304 && row
        ctx.db.cache_touch(cache_key)
        return [row["body"].b, true]
      end
      raise AdapterError, "HTTP #{r.status} desde #{host}" if r.status >= 400
      raise AdapterError, "Respuesta demasiado grande (#{r.content.bytesize} bytes) desde #{host}" if r.content.bytesize > max_bytes

      ctx.db.cache_put(cache_key, r.content, r.headers["etag"], r.headers["last-modified"])
      [r.content, false]
    end
  end
end
