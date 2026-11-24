# frozen_string_literal: true

module Aetheryon
  # NewsMesh (API externa). Cuota diaria, caché y bloqueo por licencia.
  #
  # AVISO: nombres de endpoint/parámetros/auth son configurables por entorno porque no pudieron verificarse
  # contra https://newsmesh.co/docs desde el entorno de desarrollo. El parser es tolerante con el formato.
  class NewsMeshAdapter < SourceAdapter
    def initialize
      super
      @key = "newsmesh"
      @name = "NewsMesh"
      @kind = "api"
      @url = "https://newsmesh.co/"
    end

    def self.first(d, *keys)
      keys.each do |k|
        v = d[k]
        return v unless v.nil? || v == "" || v == []
      end
      nil
    end

    def self.publisher_name(pub)
      return pub if pub.is_a?(String)
      return pub["name"] if pub.is_a?(Hash) && pub["name"].is_a?(String)

      nil
    end

    def self.parse(body, source_key)
      data =
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          raise AdapterError, "NewsMesh devolvió una respuesta que no es JSON"
        end
      arts = data.is_a?(Array) ? data : nil
      if arts.nil? && data.is_a?(Hash)
        %w[data articles results items].each do |k|
          if data[k].is_a?(Array)
            arts = data[k]
            break
          end
        end
      end
      raise AdapterError, "NewsMesh: formato de respuesta no reconocido" if arts.nil?

      arts.filter_map do |a|
        next unless a.is_a?(Hash)

        cat = first(a, "category", "categories", "topics")
        cats = cat.is_a?(Array) ? cat : (cat && cat != "" ? [cat] : [])
        pub = first(a, "source", "publisher", "source_name")
        begin
          Normalizer.build_item(
            source_key: source_key, title: first(a, "title", "headline"), url: first(a, "link", "url"),
            description: first(a, "description", "summary", "snippet"),
            published: first(a, "published_date", "published_at", "publishedAt", "date"),
            image: first(a, "image", "image_url", "media_url", "thumbnail"), author: first(a, "author", "byline"),
            external_id: first(a, "article_id", "id"), categories: cats.map(&:to_s), extra: { "publisher" => publisher_name(pub) }
          )
        rescue TypeError, ArgumentError, NoMethodError
          nil # un artículo malformado no debe tumbar toda la respuesta
        end
      end
    end

    def min_interval_min(settings) = settings.newsmesh_min_interval_min

    def availability(s)
      return "NEWSMESH_API_KEY no configurada" if s.newsmesh_api_key.nil? || s.newsmesh_api_key.empty?
      if s.app_env == "production" && s.newsmesh_plan != "commercial"
        return "El plan gratuito de NewsMesh es solo para desarrollo/pruebas: " \
               "en producción requiere NEWSMESH_PLAN=commercial (plan comercial contratado)"
      end

      nil
    end

    def fetch(ctx)
      s = ctx.settings
      res = FetchResult.new
      base = "#{s.newsmesh_base_url.sub(%r{/+\z}, '')}/#{s.newsmesh_endpoint.sub(%r{\A/+}, '')}"
      guard = lambda do
        unless ctx.quota.try_consume("newsmesh", s.newsmesh_daily_limit, s.newsmesh_quota_reserve)
          raise QuotaExceeded, "Cuota diaria alcanzada (#{s.newsmesh_daily_limit} - reserva #{s.newsmesh_quota_reserve})"
        end
      end

      s.newsmesh_queries.each do |q|
        params = { s.newsmesh_query_param => q, s.newsmesh_limit_param => s.newsmesh_per_request }
        headers = {}
        if s.newsmesh_auth_mode == "header"
          headers[s.newsmesh_auth_name] = s.newsmesh_api_key
        else
          params[s.newsmesh_auth_name] = s.newsmesh_api_key
        end
        begin
          body, cached = Http.cached_get(
            ctx, "newsmesh:#{s.newsmesh_endpoint}:#{q}:#{s.newsmesh_per_request}", base,
            params: params, headers: headers, ttl_s: s.newsmesh_min_interval_min * 60, before_request: guard
          )
        rescue QuotaExceeded => e
          raise if res.items.empty? && res.requests_made.zero?

          res.warnings << e.message
          break
        end
        res.requests_made += cached ? 0 : 1
        res.items.concat(self.class.parse(body, key))
      end
      res
    end
  end
end
