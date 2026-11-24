# frozen_string_literal: true

require "digest"

module Aetheryon
  # Persistencia de noticias + deduplicación entre proveedores.
  #
  # Reglas de duplicado (en orden): 1) mismo (fuente, id externo); 2) misma URL canónica;
  # 3) mismo título normalizado EXACTO (≥4 palabras, mismo juego, ventana de 3 días).
  # Un duplicado nunca se descarta: se agrega como referencia de la noticia existente.
  module Store
    TITLE_WINDOW = 3 * 86_400
    MIN_TITLE_WORDS = 4

    IngestStats = Struct.new(:new, :duplicates, :seen) do
      def initialize(new = 0, duplicates = 0, seen = 0) = super
    end

    module_function

    def article_id(canonical_url) = "art_#{Digest::SHA1.hexdigest(canonical_url)[0, 16]}"

    def add_ref(c, art_id, it, now)
      cur = c.execute(
        "INSERT INTO article_refs(article_id, source_key, url, canonical_url, external_id, title, published_at, captured_at) " \
        "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING",
        [art_id, it.source_key, it.url, it.canonical_url, it.external_id, it.title,
         it.published_at && Util.iso(it.published_at), now]
      )
      cur.rowcount == 1
    end

    def find_existing(c, it)
      if it.external_id
        r = c.execute("SELECT article_id FROM article_refs WHERE source_key=? AND external_id=?", [it.source_key, it.external_id]).fetchone
        return r["article_id"] if r
      end
      r = c.execute("SELECT article_id FROM article_refs WHERE canonical_url=?", [it.canonical_url]).fetchone
      return r["article_id"] if r

      if Util.py_split(it.title_key).length >= MIN_TITLE_WORDS
        ref_dt = it.published_at || Util.utcnow
        c.execute("SELECT id, sort_at, game_appid FROM articles WHERE title_key=?", [it.title_key]).each do |row|
          next if row["game_appid"] != it.game_appid

          other = begin
            Util.parse_iso(row["sort_at"])
          rescue ArgumentError
            next
          end
          return row["id"] if (other - ref_dt).abs <= TITLE_WINDOW
        end
      end
      nil
    end

    def ingest(db, items)
      stats = IngestStats.new
      now = Util.utcnow_iso
      db.conn do |c|
        # Serializa la ingesta (entre hilos y procesos): sin esto, dos fuentes que traen la misma
        # noticia a la vez podrían pasar ambas el chequeo de duplicados e insertarla dos veces.
        c.execute("SELECT pg_advisory_xact_lock(?)", [LOCK_INGEST])
        items.each do |it|
          existing = find_existing(c, it)
          if existing
            if add_ref(c, existing, it, now)
              stats.duplicates += 1
            else
              stats.seen += 1
            end
            c.execute("UPDATE articles SET image_url=? WHERE id=? AND image_url IS NULL", [it.image_url, existing]) if it.image_url
            next
          end
          aid = article_id(it.canonical_url)
          sort_at = Util.iso(it.published_at || Util.utcnow)
          original = { "categories" => it.source_categories, "tags" => it.source_tags, "extra" => it.extra }
          c.execute(
            "INSERT INTO articles(id, title, description, source_key, url, canonical_url, published_at, captured_at, sort_at, " \
            "image_url, author, external_id, title_key, game_appid, original) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [aid, it.title, it.description, it.source_key, it.url, it.canonical_url,
             it.published_at && Util.iso(it.published_at), now, sort_at,
             it.image_url, it.author, it.external_id, it.title_key, it.game_appid, JSON.generate(original)]
          )
          add_ref(c, aid, it, now)
          cl = Classifier.classify(it)
          c.execute(
            "INSERT INTO classifications(article_id, categories, tags, platforms, method, version, confidence, generated_at) " \
            "VALUES(?,?,?,?,?,?,?,?)",
            [aid, JSON.generate(cl.categories), JSON.generate(cl.tags), JSON.generate(cl.platforms),
             cl.rule_method, cl.version, cl.confidence, now]
          )
          c.executemany("INSERT INTO article_categories(article_id, category) VALUES(?,?) ON CONFLICT DO NOTHING", cl.categories.map { |x| [aid, x] })
          c.executemany("INSERT INTO article_platforms(article_id, platform) VALUES(?,?) ON CONFLICT DO NOTHING", cl.platforms.map { |x| [aid, x] })
          stats.new += 1
        end
      end
      stats
    end
  end
end
