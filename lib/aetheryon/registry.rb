# frozen_string_literal: true

module Aetheryon
  # Registro de fuentes. Para sumar un proveedor: crear el adaptador y agregarlo acá.
  module Registry
    RSS_FEEDS = [
      ["ign", "IGN", "https://www.ign.com/rss/v2/articles/feed"],
      ["pcgamer", "PC Gamer", "https://www.pcgamer.com/rss/"],
      ["eurogamer", "Eurogamer", "https://www.eurogamer.net/feed"],
      ["gamespot", "GameSpot", "https://www.gamespot.com/feeds/news/"],
      ["kotaku", "Kotaku", "https://kotaku.com/feed"],
      ["rockpapershotgun", "Rock Paper Shotgun", "https://www.rockpapershotgun.com/feed"],
      ["nintendolife", "Nintendo Life", "https://www.nintendolife.com/feeds/latest"]
    ].freeze

    module_function

    def build_adapters = RSS_FEEDS.map { |f| RssAdapter.new(*f) } + [NewsMeshAdapter.new, SteamAdapter.new]

    def sync_sources_table(db, adapters)
      db.conn do |c|
        adapters.each do |a|
          c.execute(
            "INSERT INTO sources(key, name, kind, url) VALUES(?,?,?,?) " \
            "ON CONFLICT(key) DO UPDATE SET name=excluded.name, kind=excluded.kind, url=excluded.url",
            [a.key, a.name, a.kind, a.url]
          )
        end
      end
    end
  end
end
