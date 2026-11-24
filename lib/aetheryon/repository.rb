# frozen_string_literal: true

module Aetheryon
  # Consultas de lectura. Todo el SQL de lectura vive acá; las rutas solo validan y delegan.
  module Repository
    BASE = "SELECT a.*, s.name AS source_name, g.name AS game_name FROM articles a " \
           "LEFT JOIN sources s ON s.key=a.source_key LEFT JOIN games g ON g.appid=a.game_appid"

    Filters = Struct.new(:sources, :categories, :platforms, :game, :date_from, :date_to, :q, keyword_init: true) do
      def initialize(**kw) = super(sources: [], categories: [], platforms: [], game: nil, date_from: nil, date_to: nil, q: nil, **kw)
    end

    module_function

    def esc(t) = t.gsub(/[\\%_]/) { |m| "\\#{m}" }

    def placeholders(n) = (["?"] * n).join(",")

    def where(f)
      c = []
      p = []
      unless f.sources.empty?
        c << "a.id IN (SELECT article_id FROM article_refs WHERE source_key IN (#{placeholders(f.sources.size)}))"
        p += f.sources
      end
      unless f.categories.empty?
        c << "a.id IN (SELECT article_id FROM article_categories WHERE category IN (#{placeholders(f.categories.size)}))"
        p += f.categories
      end
      unless f.platforms.empty?
        c << "a.id IN (SELECT article_id FROM article_platforms WHERE platform IN (#{placeholders(f.platforms.size)}))"
        p += f.platforms
      end
      unless f.game.nil?
        c << "a.game_appid=?"
        p << f.game
      end
      if f.date_from && !f.date_from.empty?
        c << "a.sort_at>=?"
        p << f.date_from
      end
      if f.date_to && !f.date_to.empty?
        c << "a.sort_at<=?"
        p << f.date_to
      end
      Util.py_split(f.q || "").each do |tok|
        like = "%#{esc(tok)}%"
        c << "(a.title ILIKE ? ESCAPE '\\' OR a.description ILIKE ? ESCAPE '\\')"
        p << like << like
      end
      [c.empty? ? "" : " WHERE #{c.join(' AND ')}", p]
    end

    def hydrate(conn, rows)
      return [] if rows.empty?

      ids = rows.map { |r| r["id"] }
      q = placeholders(ids.size)
      cls = conn.execute("SELECT * FROM classifications WHERE article_id IN (#{q})", ids).to_h { |r| [r["article_id"], r] }
      refs = Hash.new { |h, k| h[k] = [] }
      conn.execute(
        "SELECT r.*, s.name AS source_name FROM article_refs r LEFT JOIN sources s ON s.key=r.source_key " \
        "WHERE r.article_id IN (#{q}) ORDER BY r.captured_at, r.source_key", ids
      ).each do |r|
        refs[r["article_id"]] << { "source" => r["source_key"], "source_name" => r["source_name"], "url" => r["url"],
                                   "published_at" => r["published_at"], "captured_at" => r["captured_at"] }
      end
      rows.map do |r|
        c = cls[r["id"]]
        orig = JSON.parse(r["original"] || "{}")
        {
          "id" => r["id"], "title" => r["title"], "description" => r["description"],
          "source" => { "key" => r["source_key"], "name" => r["source_name"] },
          "url" => r["url"], "canonical_url" => r["canonical_url"], "published_at" => r["published_at"],
          "captured_at" => r["captured_at"], "image_url" => r["image_url"], "author" => r["author"],
          "categories" => c ? JSON.parse(c["categories"]) : [], "tags" => c ? JSON.parse(c["tags"]) : [],
          "platforms" => c ? JSON.parse(c["platforms"]) : [],
          "game" => r["game_appid"] ? { "appid" => r["game_appid"], "name" => r["game_name"] } : nil,
          "references" => refs.key?(r["id"]) ? refs[r["id"]] : [],
          "original" => { "categories" => orig.fetch("categories", []), "tags" => orig.fetch("tags", []),
                          "external_id" => r["external_id"], "extra" => orig.fetch("extra", {}) },
          "classification" => c ? { "method" => c["method"], "version" => c["version"], "confidence" => c["confidence"],
                                    "generated_at" => c["generated_at"] } : nil
        }
      end
    end

    def list_articles(db, f, page, page_size)
      wh, params = where(f)
      db.conn do |c|
        total = c.execute("SELECT COUNT(*) FROM articles a#{wh}", params).fetchone[0]
        rows = c.execute("#{BASE}#{wh} ORDER BY a.sort_at DESC, a.id LIMIT ? OFFSET ?", params + [page_size, (page - 1) * page_size]).fetchall
        items = hydrate(c, rows)
        { "items" => items, "page" => page, "page_size" => page_size, "total" => total,
          "pages" => [1, (total.to_f / page_size).ceil].max }
      end
    end

    def get_article(db, article_id)
      db.conn do |c|
        rows = c.execute("#{BASE} WHERE a.id=?", [article_id]).fetchall
        hydrate(c, rows).first
      end
    end

    # Puntaje = 3 × medios distintos que cubren la noticia + frescura (0–2) dentro de la ventana.
    def trending(db, hours, limit, f)
      now = Util.utcnow
      f.date_from = Util.iso(now - hours * 3600)
      wh, params = where(f)
      db.conn do |c|
        rows = c.execute("#{BASE}#{wh} ORDER BY a.sort_at DESC LIMIT 500", params).fetchall
        n_src = c.execute("SELECT article_id, COUNT(DISTINCT source_key) n FROM article_refs GROUP BY article_id").to_h { |r| [r["article_id"], r["n"]] }
        scored = rows.map do |r|
          age_h = [0.0, (now - Util.parse_iso(r["sort_at"])) / 3600].max
          [3 * n_src.fetch(r["id"], 1) + 2 * [0.0, 1 - age_h / hours].max, r]
        end
        top = scored.each_with_index.sort_by { |(s, _), i| [-s, i] }.map(&:first).first(limit)
        items = hydrate(c, top.map { |_, r| r })
        items.zip(top).each { |it, (s, _)| it["score"] = s.round(2) }
        items
      end
    end

    def categories(db)
      counts = db.conn { |c| c.execute("SELECT category, COUNT(*) n FROM article_categories GROUP BY category").to_h { |r| [r["category"], r["n"]] } }
      Classifier::CATEGORIES.map { |k| { "name" => k, "count" => counts.fetch(k, 0) } }
    end

    def sources(db)
      db.conn do |c|
        rows = c.execute("SELECT * FROM sources ORDER BY kind DESC, name").fetchall
        n = c.execute("SELECT source_key, COUNT(*) n FROM articles GROUP BY source_key").to_h { |r| [r["source_key"], r["n"]] }
        rows.map { |r| r.to_h.merge("enabled" => r["enabled"] != 0, "stored_articles" => n.fetch(r["key"], 0)) }
      end
    end
  end
end
