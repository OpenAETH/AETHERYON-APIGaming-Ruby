# frozen_string_literal: true

module Aetheryon
  module Editorial
    # Distribución: solo noticias con procesamiento completado. Consultas de lectura de la versión editorial.
    module Processed
      FROM = " FROM articles a JOIN news_queue q ON q.article_id=a.id JOIN news_editorial e ON e.article_id=a.id"

      ProcessedFilters = Struct.new(:sources, :categories, :languages, :translated, :date_from, :date_to, keyword_init: true) do
        def initialize(**kw) = super(sources: [], categories: [], languages: [], translated: nil, date_from: nil, date_to: nil, **kw)
      end

      module_function

      def where(f)
        c = ["q.status='completed'"]
        p = []
        unless f.sources.empty? # igual que /api/news: incluye medios que citan la misma noticia
          c << "a.id IN (SELECT article_id FROM article_refs WHERE source_key IN (#{Repository.placeholders(f.sources.size)}))"
          p += f.sources
        end
        unless f.categories.empty?
          c << "a.id IN (SELECT article_id FROM news_editorial_categories WHERE category IN (#{Repository.placeholders(f.categories.size)}))"
          p += f.categories
        end
        unless f.languages.empty?
          c << "e.source_language IN (#{Repository.placeholders(f.languages.size)})"
          p += f.languages
        end
        unless f.translated.nil?
          c << "e.translated=?"
          p << (f.translated ? 1 : 0)
        end
        if f.date_from && !f.date_from.empty?
          c << "a.sort_at>=?"
          p << f.date_from
        end
        if f.date_to && !f.date_to.empty?
          c << "a.sort_at<=?"
          p << f.date_to
        end
        [" WHERE #{c.join(' AND ')}", p]
      end

      def item(art, e, q)
        {
          "id" => art["id"], "status" => "completed", "url" => art["url"], "canonical_url" => art["canonical_url"],
          "published_at" => art["published_at"], "captured_at" => art["captured_at"], "image_url" => art["image_url"],
          "author" => art["author"], "source" => art["source"], "game" => art["game"], "references" => art["references"],
          "original" => art["original"],
          "normalized" => { "title" => art["title"], "description" => art["description"], "categories" => art["categories"],
                            "tags" => art["tags"], "platforms" => art["platforms"], "classification" => art["classification"] },
          "editorial" => { "language" => e["language"], "source_language" => e["source_language"], "translated" => e["translated"] != 0,
                           "title" => e["title"], "summary" => e["summary"], "body" => e["body"], "category" => e["category"],
                           "categories" => JSON.parse(e["categories"]), "entities" => JSON.parse(e["entities"]),
                           "uncertainty" => JSON.parse(e["uncertainty"]), "insufficient_info" => e["insufficient_info"] != 0 },
          "processing" => { "model" => e["model"], "pipeline_version" => e["pipeline_version"], "content_hash" => e["content_hash"],
                            "generated_at" => e["generated_at"], "attempts" => q["attempts"],
                            "tokens" => { "prompt" => e["prompt_tokens"], "completion" => e["completion_tokens"] } }
        }
      end

      def list_processed(db, f, page, page_size)
        wh, params = where(f)
        db.conn do |c|
          total = c.execute("SELECT COUNT(*)#{FROM}#{wh}", params).fetchone[0]
          ids = c.execute("SELECT a.id#{FROM}#{wh} ORDER BY a.sort_at DESC, a.id LIMIT ? OFFSET ?", params + [page_size, (page - 1) * page_size]).map { |r| r["id"] }
          items = []
          unless ids.empty?
            q = Repository.placeholders(ids.size)
            rows = c.execute("#{Repository::BASE} WHERE a.id IN (#{q})", ids).to_h { |r| [r["id"], r] }
            arts = Repository.hydrate(c, ids.map { |i| rows[i] }).to_h { |a| [a["id"], a] }
            eds = c.execute("SELECT * FROM news_editorial WHERE article_id IN (#{q})", ids).to_h { |r| [r["article_id"], r] }
            qs = c.execute("SELECT article_id, attempts FROM news_queue WHERE article_id IN (#{q})", ids).to_h { |r| [r["article_id"], r] }
            items = ids.map { |i| item(arts[i], eds[i], qs[i]) }
          end
          { "items" => items, "page" => page, "page_size" => page_size, "total" => total, "pages" => [1, (total.to_f / page_size).ceil].max }
        end
      end

      # Vista plana para consumidores (Terra Gazette, AETHERYON Radio): el texto en español es de primer nivel.
      def flatten_es(it)
        e = it["editorial"]
        {
          "id" => it["id"], "language" => e["language"], "title" => e["title"], "summary" => e["summary"], "body" => e["body"],
          "category" => e["category"], "categories" => e["categories"], "entities" => e["entities"],
          "uncertainty" => e["uncertainty"], "insufficient_info" => e["insufficient_info"],
          "translated" => e["translated"], "source_language" => e["source_language"],
          "original_title" => it["normalized"]["title"], "url" => it["url"], "source" => it["source"],
          "published_at" => it["published_at"], "image_url" => it["image_url"], "author" => it["author"],
          "game" => it["game"], "references" => it["references"],
          "generated_at" => it["processing"]["generated_at"], "model" => it["processing"]["model"]
        }
      end

      def pending_count(db)
        db.conn { |c| c.execute("SELECT COUNT(*) FROM news_queue WHERE status IN ('pending','processing')").fetchone[0] }
      end
    end
  end
end
