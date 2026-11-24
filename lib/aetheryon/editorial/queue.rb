# frozen_string_literal: true

require "digest"

module Aetheryon
  module Editorial
    # Cola de procesamiento editorial: alta (intake), reclamo concurrente seguro, transiciones de estado y consumo.
    module WorkQueue
      STATUSES = %w[pending processing completed failed].freeze

      CLAIM = "UPDATE news_queue SET status='processing', started_at=?, lease_until=?, attempts=attempts+1 WHERE article_id IN (" \
              "SELECT article_id FROM news_queue WHERE {cond} ORDER BY priority DESC, enqueued_at LIMIT ? FOR UPDATE SKIP LOCKED) " \
              "RETURNING article_id, attempts, content_hash"

      ITEM_SQL = "SELECT q.*, a.title, a.source_key, s.name AS source_name FROM news_queue q JOIN articles a ON a.id=q.article_id " \
                 "LEFT JOIN sources s ON s.key=a.source_key"

      module_function

      def content_hash(title, description) = Digest::SHA256.hexdigest("#{title}\n#{description || ''}")[0, 32]

      # ---------------------------------------------------------------- alta
      # Encola noticias (hashes con id/title/description). Idempotente: no reprocesa lo ya completado con el mismo
      # contenido y la misma versión de pipeline; reencola si cambió alguno de los dos (o con force).
      def enqueue(db, items, by, priority = 0, force = false)
        out = { "enqueued" => 0, "requeued" => 0, "skipped" => 0 }
        now = Util.utcnow_iso
        db.conn do |c|
          items.each do |it|
            h = content_hash(it["title"], it["description"])
            cur = c.execute(
              "INSERT INTO news_queue(article_id, status, priority, enqueued_by, content_hash, pipeline_version, enqueued_at) " \
              "VALUES(?,'pending',?,?,?,?,?) ON CONFLICT(article_id) DO NOTHING",
              [it["id"], priority, by, h, Prompts::PIPELINE_VERSION, now]
            )
            if cur.rowcount == 1
              out["enqueued"] += 1
              next
            end
            row = c.execute("SELECT status, content_hash, pipeline_version, priority FROM news_queue WHERE article_id=?", [it["id"]]).fetchone
            if row.nil?
              out["skipped"] += 1
              next
            end
            st = row["status"]
            if %w[pending processing].include?(st)
              c.execute("UPDATE news_queue SET priority=? WHERE article_id=? AND status='pending'", [priority, it["id"]]) if st == "pending" && priority > row["priority"]
              out["skipped"] += 1
              next
            end
            stale = row["content_hash"] != h || row["pipeline_version"] != Prompts::PIPELINE_VERSION
            unless stale || force || (st == "failed" && by == "manual")
              out["skipped"] += 1
              next
            end
            n = c.execute(
              "UPDATE news_queue SET status='pending', priority=?, enqueued_by=?, content_hash=?, pipeline_version=?, attempts=0, " \
              "enqueued_at=?, started_at=NULL, finished_at=NULL, next_attempt_at=NULL, lease_until=NULL, last_error=NULL " \
              "WHERE article_id=? AND status=?",
              [priority, by, h, Prompts::PIPELINE_VERSION, now, it["id"], st]
            ).rowcount
            out[n.positive? ? "requeued" : "skipped"] += 1
          end
        end
        out
      end

      # Lee lo mismo que sirven /api/news/trending y /api/news/latest (mismas funciones de Repository) y lo encola.
      def intake(db, settings)
        since = Util.iso(Util.utcnow - settings.editorial_intake_hours * 3600)
        trending = Repository.trending(db, settings.editorial_intake_hours, settings.editorial_trending_limit, Repository::Filters.new)
        latest = Repository.list_articles(db, Repository::Filters.new(date_from: since), 1, settings.editorial_latest_limit)["items"]
        seen = trending.map { |t| t["id"] }
        a = enqueue(db, trending, "trending", 10)
        b = enqueue(db, latest.reject { |x| seen.include?(x["id"]) }, "latest", 0)
        a.to_h { |k, v| [k, v + b[k]] }
      end

      # ---------------------------------------------------------------- reclamo
      def reclaim_expired(c, settings, now)
        c.execute(
          "UPDATE news_queue SET status=CASE WHEN attempts>=? THEN 'failed' ELSE 'pending' END, " \
          "finished_at=CASE WHEN attempts>=? THEN ? ELSE finished_at END, lease_until=NULL, " \
          "last_error=COALESCE(last_error, 'Lease expirado (worker caído o timeout)') " \
          "WHERE status='processing' AND lease_until<?",
          [settings.editorial_max_attempts, settings.editorial_max_attempts, now, now]
        )
      end

      # Toma hasta n pendientes vencidos (SKIP LOCKED: varios workers/instancias no se pisan).
      def claim_batch(db, settings, n)
        now = Util.utcnow_iso
        lease = Util.iso(Util.utcnow + settings.editorial_lease_min * 60, timespec: "seconds")
        db.conn do |c|
          reclaim_expired(c, settings, now)
          c.execute(CLAIM.sub("{cond}", "status='pending' AND (next_attempt_at IS NULL OR next_attempt_at<=?)"), [now, lease, now, n]).fetchall.map(&:to_h)
        end
      end

      def claim_one(db, _settings, article_id)
        now = Util.utcnow_iso
        lease = Util.iso(Util.utcnow + _settings.editorial_lease_min * 60, timespec: "seconds")
        db.conn do |c|
          rows = c.execute(CLAIM.sub("{cond}", "status='pending' AND article_id=?"), [now, lease, article_id, 1]).fetchall
          rows.empty? ? nil : rows[0].to_h
        end
      end

      # ---------------------------------------------------------------- transiciones
      # Guarda la versión editorial y cierra el ítem. false si el ítem ya no es el reclamado (reencolado, borrado).
      def complete(db, article_id, claimed_hash, current_hash, ed, model, prompt_tokens, completion_tokens)
        now = Util.utcnow_iso
        db.conn do |c|
          n = c.execute(
            "UPDATE news_queue SET status='completed', finished_at=?, lease_until=NULL, last_error=NULL, content_hash=? " \
            "WHERE article_id=? AND status='processing' AND content_hash=?",
            [now, current_hash, article_id, claimed_hash]
          ).rowcount
          return false if n != 1

          c.execute(
            "INSERT INTO news_editorial(article_id, source_language, language, translated, title, summary, body, category, categories, " \
            "entities, uncertainty, insufficient_info, model, pipeline_version, content_hash, generated_at, prompt_tokens, completion_tokens) " \
            "VALUES(?,?,'es',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(article_id) DO UPDATE SET " \
            "source_language=EXCLUDED.source_language, translated=EXCLUDED.translated, title=EXCLUDED.title, summary=EXCLUDED.summary, " \
            "body=EXCLUDED.body, category=EXCLUDED.category, categories=EXCLUDED.categories, entities=EXCLUDED.entities, " \
            "uncertainty=EXCLUDED.uncertainty, insufficient_info=EXCLUDED.insufficient_info, model=EXCLUDED.model, " \
            "pipeline_version=EXCLUDED.pipeline_version, content_hash=EXCLUDED.content_hash, generated_at=EXCLUDED.generated_at, " \
            "prompt_tokens=EXCLUDED.prompt_tokens, completion_tokens=EXCLUDED.completion_tokens",
            [article_id, ed.source_language, ed.translated ? 1 : 0, ed.title, ed.summary, ed.body, ed.category,
             JSON.generate(ed.categories), JSON.generate(ed.entities), JSON.generate(ed.uncertainty),
             ed.insufficient_info ? 1 : 0, model, Prompts::PIPELINE_VERSION, current_hash, now, prompt_tokens, completion_tokens]
          )
          c.execute("DELETE FROM news_editorial_categories WHERE article_id=?", [article_id])
          c.executemany("INSERT INTO news_editorial_categories(article_id, category) VALUES(?,?) ON CONFLICT DO NOTHING",
                        ed.categories.map { |x| [article_id, x] })
          true
        end
      end

      # Devuelve 'failed' (agotó intentos o no reintentable), 'retry' (vuelve a pending con backoff) o 'skipped'.
      def fail(db, settings, article_id, error, retriable = true)
        now = Util.utcnow
        db.conn do |c|
          row = c.execute("SELECT attempts FROM news_queue WHERE article_id=? AND status='processing'", [article_id]).fetchone
          return "skipped" if row.nil?

          if !retriable || row["attempts"] >= settings.editorial_max_attempts
            c.execute("UPDATE news_queue SET status='failed', finished_at=?, lease_until=NULL, last_error=? WHERE article_id=?",
                      [Util.iso(now, timespec: "seconds"), error[0, 500], article_id])
            return "failed"
          end
          delay = [3600, 30 * 2**(row["attempts"] - 1)].min
          c.execute("UPDATE news_queue SET status='pending', next_attempt_at=?, lease_until=NULL, last_error=? WHERE article_id=?",
                    [Util.iso(now + delay, timespec: "seconds"), error[0, 500], article_id])
          "retry"
        end
      end

      # ---------------------------------------------------------------- consumo y consulta
      def log_usage(db, article_id, model, status, prompt_tokens = 0, completion_tokens = 0, total_tokens = 0, latency_ms = 0, retries = 0, error = nil)
        db.conn do |c|
          c.execute(
            "INSERT INTO llm_usage(article_id, model, status, prompt_tokens, completion_tokens, total_tokens, latency_ms, " \
            "retries, error, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
            [article_id, model, status, prompt_tokens, completion_tokens, total_tokens, latency_ms, retries,
             error.nil? || error.empty? ? nil : error[0, 300], Util.utcnow_iso]
          )
        end
      end

      def usage_today(db)
        day = Util.utcnow.strftime("%Y-%m-%d")
        r = db.conn do |c|
          c.execute(
            "SELECT COUNT(*) calls, COALESCE(SUM(CASE WHEN status='ok' THEN 1 ELSE 0 END),0) ok, " \
            "COALESCE(SUM(CASE WHEN status='error' THEN 1 ELSE 0 END),0) errors, " \
            "COALESCE(SUM(CASE WHEN status='rejected' THEN 1 ELSE 0 END),0) rejected, " \
            "COALESCE(SUM(prompt_tokens),0) prompt_tokens, COALESCE(SUM(completion_tokens),0) completion_tokens, " \
            "COALESCE(SUM(total_tokens),0) total_tokens, COALESCE(SUM(retries),0) retries " \
            "FROM llm_usage WHERE created_at>=?", [day]
          ).fetchone
        end
        r.to_h.transform_values(&:to_i)
      end

      def item(r, settings)
        { "id" => r["article_id"], "title" => r["title"], "source" => { "key" => r["source_key"], "name" => r["source_name"] },
          "status" => r["status"], "priority" => r["priority"], "attempts" => r["attempts"],
          "max_attempts" => settings.editorial_max_attempts, "enqueued_by" => r["enqueued_by"],
          "pipeline_version" => r["pipeline_version"], "enqueued_at" => r["enqueued_at"], "started_at" => r["started_at"],
          "finished_at" => r["finished_at"], "next_attempt_at" => r["next_attempt_at"], "last_error" => r["last_error"] }
      end

      def get_item(db, settings, article_id)
        r = db.conn { |c| c.execute("#{ITEM_SQL} WHERE q.article_id=?", [article_id]).fetchone }
        r ? item(r, settings) : nil
      end

      def queue_page(db, settings, status, page, page_size)
        wh, params = status ? [" WHERE q.status=?", [status]] : ["", []]
        order = %w[pending processing].include?(status) ? "q.priority DESC, q.enqueued_at" : "COALESCE(q.finished_at, q.enqueued_at) DESC"
        total, rows, counts = db.conn do |c|
          [
            c.execute("SELECT COUNT(*) FROM news_queue q#{wh}", params).fetchone[0],
            c.execute("#{ITEM_SQL}#{wh} ORDER BY #{order}, q.article_id LIMIT ? OFFSET ?", params + [page_size, (page - 1) * page_size]).fetchall,
            c.execute("SELECT status, COUNT(*) n FROM news_queue GROUP BY status").to_h { |r| [r["status"], r["n"]] }
          ]
        end
        { "items" => rows.map { |r| item(r, settings) }, "page" => page, "page_size" => page_size, "total" => total,
          "pages" => [1, (total.to_f / page_size).ceil].max, "counts" => STATUSES.to_h { |s| [s, counts.fetch(s, 0)] },
          "usage_today" => usage_today(db),
          "worker" => { "enabled" => !settings.groq_api_key.to_s.empty?, "model" => settings.groq_model,
                        "pipeline_version" => Prompts::PIPELINE_VERSION } }
      end
    end
  end
end
