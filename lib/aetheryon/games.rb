# frozen_string_literal: true

require "fileutils"

module Aetheryon
  # Catálogo de juegos: resolución de AppID por URL, catálogo público de Steam o carga manual.
  # SteamDB solo se admite como formato de URL a parsear; nunca se consulta en tiempo de ejecución.
  class SteamCatalog
    APPID_URL_RE = %r{(?:store\.steampowered\.com|steamcommunity\.com|steamdb\.info)/app/(\d+)}i
    APPLIST_URL = "https://api.steampowered.com/ISteamApps/GetAppList/v2/"
    APPLIST_TTL = 24 * 3600

    def initialize(client_getter, data_dir)
      @client_getter = client_getter
      @data_dir = data_dir
      @mutex = Mutex.new
      @index = nil
      @index_ts = 0.0
    end

    def self.appid_from_url(url)
      m = APPID_URL_RE.match(url.to_s)
      m ? m[1].to_i : nil
    end

    # Busca en el catálogo público de Steam. Lanza RuntimeError si no está disponible.
    def search(q, limit = 20)
      apps = load_applist
      rows = @mutex.synchronize do
        if @index.nil? || Time.now.to_f - @index_ts > APPLIST_TTL || @index[:n] != apps.size
          @index = { n: apps.size, rows: apps.select { |a| a["name"] && !a["name"].empty? }.map { |a| [Normalizer.title_key(a["name"]), a] } }
          @index_ts = Time.now.to_f
        end
        @index[:rows]
      end
      k = Normalizer.title_key(q)
      return [[], 0] if k.empty?

      exact = []
      prefix = []
      contains = []
      rows.each do |key, a|
        if key == k then exact << a
        elsif key.start_with?(k) then prefix << a
        elsif key.include?(k) then contains << a
        end
      end
      found = (exact + prefix + contains).first(limit).map { |a| { "appid" => a["appid"], "name" => a["name"] } }
      [found, exact.size]
    end

    # Devuelve [appid|nil, método|nil, candidatos]. Nunca lanza: si falla, se carga manualmente.
    def resolve(name:, url:)
      appid = self.class.appid_from_url(url)
      return [appid, "url", []] if appid

      if name && !name.empty?
        begin
          matches, n_exact = search(name, 10)
        rescue RuntimeError
          return [nil, nil, []]
        end
        return [matches[0]["appid"], "catalog", matches] if n_exact == 1

        return [nil, nil, matches]
      end
      [nil, nil, []]
    end

    private

    def load_applist
      path = File.join(@data_dir, "steam_applist.json")
      return JSON.parse(File.read(path)) if File.exist?(path) && Time.now.to_f - File.mtime(path).to_f < APPLIST_TTL

      begin
        r = @client_getter.call.get(APPLIST_URL, timeout: 60)
        raise HttpError, "HTTPStatusError" if r.status >= 400

        apps = r.json["applist"]["apps"]
      rescue StandardError => e
        return JSON.parse(File.read(path)) if File.exist?(path) # catálogo vencido pero utilizable

        name = e.is_a?(HttpError) ? e.message : e.class.name.split("::").last
        raise "Catálogo público de Steam no disponible (#{name})"
      end
      FileUtils.mkdir_p(@data_dir)
      File.write(path, JSON.generate(apps))
      apps
    end
  end
end
