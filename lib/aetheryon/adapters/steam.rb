# frozen_string_literal: true

module Aetheryon
  # Steam News (ISteamNews/GetNewsForApp). Un adaptador, N juegos del catálogo; falla por juego, no global.
  class SteamAdapter < SourceAdapter
    STEAM_NEWS_URL = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/"
    BB_IMG = %r{\[img[^\]]*\](.*?)\[/img\]}mi
    CLAN_IMG = "https://clan.akamai.steamstatic.com/images"

    def initialize
      super
      @key = "steam"
      @name = "Steam News"
      @kind = "api"
      @url = STEAM_NEWS_URL
    end

    # Mejor esfuerzo: primera imagen en el contenido (BBCode o URL directa).
    def self.steam_image(contents)
      return nil if contents.nil? || contents.empty?

      m = BB_IMG.match(contents)
      cand = m ? Util.py_strip(m[1]) : nil
      if cand.nil? || cand.empty?
        m2 = %r{https?://\S+?\.(?:png|jpe?g|gif|webp)}i.match(contents)
        cand = m2 ? m2[0] : nil
      end
      cand = cand.gsub("{STEAM_CLAN_IMAGE}", CLAN_IMG) if cand
      Normalizer.clean_url(cand)
    end

    def min_interval_min(settings) = settings.steam_min_interval_min

    def fetch(ctx)
      games = ctx.db.games_for_sync(ctx.settings.steam_max_games_per_run)
      return FetchResult.new(warnings: ["Catálogo sin juegos activos con AppID: nada que consultar"]) if games.empty?

      queue = Queue.new
      games.each_with_index { |g, i| queue << [g, i] }
      results = Array.new(games.size)
      workers = Array.new([3, games.size].min) do
        Thread.new do
          Thread.current.report_on_exception = false
          loop do
            g, i = queue.pop(true)
            results[i] =
              begin
                items, reqs = fetch_game(ctx, g)
                ctx.db.mark_game_synced(g["id"], items.size, nil)
                [items, reqs, nil]
              rescue StandardError => e # aislamiento por juego
                msg = e.is_a?(AdapterError) ? e.message : e.class.name.split("::").last
                ctx.db.mark_game_synced(g["id"], 0, msg)
                [[], 0, "#{g['name']} (#{g['appid']}): #{msg}"]
              end
          rescue ThreadError
            break
          end
        end
      end
      workers.each(&:join)
      res = FetchResult.new
      errors = []
      results.each do |items, reqs, err|
        res.items.concat(items)
        res.requests_made += reqs
        errors << err if err
      end
      raise AdapterError, "Todos los juegos fallaron: #{errors.first(3).join('; ')}" if !errors.empty? && errors.size == games.size

      res.warnings.concat(errors)
      res
    end

    def fetch_game(ctx, g)
      s = ctx.settings
      body, cached = Http.cached_get(
        ctx, "steam:#{g['appid']}", STEAM_NEWS_URL,
        params: { "appid" => g["appid"], "count" => s.steam_news_count, "maxlength" => 500, "format" => "json" },
        ttl_s: s.steam_min_interval_min * 60
      )
      raw =
        begin
          data = JSON.parse(body)
          r = data.is_a?(Hash) && data["appnews"].is_a?(Hash) ? data["appnews"]["newsitems"] : nil
          raise TypeError unless r.is_a?(Array)

          r
        rescue JSON::ParserError, TypeError
          raise AdapterError, "Respuesta de Steam con formato no reconocido"
        end
      items = raw.filter_map do |n|
        next unless n.is_a?(Hash)

        Normalizer.build_item(
          source_key: key, title: n["title"], url: n["url"], description: n["contents"], published: n["date"],
          image: self.class.steam_image(n["contents"]), author: n["author"], external_id: n["gid"],
          categories: n["feedlabel"] && n["feedlabel"] != "" ? [n["feedlabel"]] : [], tags: n["tags"] || [],
          game_appid: g["appid"].to_i, platform_hint: g["platform"], bbcode: true,
          extra: { "feedname" => n["feedname"], "feed_type" => n["feed_type"], "is_external_url" => n["is_external_url"],
                   "game_name" => g["name"] }
        )
      end
      [items, cached ? 0 : 1]
    end
  end
end
