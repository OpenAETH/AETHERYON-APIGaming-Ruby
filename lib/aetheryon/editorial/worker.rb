# frozen_string_literal: true

module Aetheryon
  module Editorial
    # Worker: intake → reclamo → Groq → validación → persistencia, con reintentos y control de errores.
    class Worker
      def initialize(db, settings, get_client)
        @db = db
        @settings = settings
        @get_client = get_client
        @groq = nil
        @groq_lock = Mutex.new
        @log = Aetheryon.log("editorial")
      end

      def enabled? = !@settings.groq_api_key.to_s.empty?
      alias enabled enabled?

      def client = @groq_lock.synchronize { @groq ||= GroqClient.new(@get_client.call, @settings) }

      def load_article(article_id)
        a, cl = @db.conn do |c|
          a = c.execute("SELECT a.id, a.title, a.description, a.source_key, s.name AS source_name FROM articles a " \
                        "LEFT JOIN sources s ON s.key=a.source_key WHERE a.id=?", [article_id]).fetchone
          [a, a && c.execute("SELECT categories FROM classifications WHERE article_id=?", [article_id]).fetchone]
        end
        return nil if a.nil?

        cats = cl ? JSON.parse(cl["categories"]) : []
        a.to_h.merge("fallback_category" => cats.first || "gaming")
      end

      # Procesa un ítem reclamado. Devuelve completed | failed | retry | skipped.
      def process_claimed(claim)
        s = @settings
        aid = claim["article_id"]
        art = load_article(aid)
        return "skipped" if art.nil?

        current_hash = WorkQueue.content_hash(art["title"], art["description"])
        messages = Prompts.build_messages(art["title"], art["description"], art["source_name"] || art["source_key"], Classifier::CATEGORIES)
        last_err = "sin respuesta"
        2.times do # 2ª ronda: se devuelve al modelo el motivo del rechazo
          begin
            res = client.chat_json(messages)
          rescue GroqError => e
            msg = Aetheryon.redact(e.message, s.secrets)
            WorkQueue.log_usage(@db, aid, s.groq_model, "error", 0, 0, 0, e.latency_ms, e.retries, msg)
            return WorkQueue.fail(@db, s, aid, msg, e.retriable)
          end
          begin
            ed = Validate.parse_output(res.text, art["title"], art["description"], Classifier::CATEGORIES, art["fallback_category"])
          rescue Validate::ValidationError => ve
            last_err = ve.message
            WorkQueue.log_usage(@db, aid, res.model, "rejected", res.prompt_tokens, res.completion_tokens, res.total_tokens,
                            res.latency_ms, res.retries, last_err)
            messages += [
              { "role" => "assistant", "content" => res.text },
              { "role" => "user", "content" => "Tu respuesta fue rechazada: #{last_err}. Corrígela y devuelve solo el JSON, " \
                                               "sin agregar datos que no estén en el texto original." }
            ]
            next
          end
          WorkQueue.log_usage(@db, aid, res.model, "ok", res.prompt_tokens, res.completion_tokens, res.total_tokens, res.latency_ms, res.retries)
          ok = WorkQueue.complete(@db, aid, claim["content_hash"], current_hash, ed, res.model, res.prompt_tokens, res.completion_tokens)
          return ok ? "completed" : "skipped"
        end
        WorkQueue.fail(@db, s, aid, Aetheryon.redact("Validación editorial: #{last_err}", s.secrets), true)
      end

      # un ítem nunca debe tumbar el lote
      def safe(claim)
        process_claimed(claim)
      rescue StandardError => e
        @log.error("Fallo inesperado procesando #{claim['article_id']}: #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
        WorkQueue.fail(@db, @settings, claim["article_id"], "Error interno: #{e.class.name.split('::').last}", true)
      end

      def run_batch(n: nil, intake: true)
        return { "enabled" => false } unless enabled?

        stats = { "enabled" => true, "intake" => nil, "claimed" => 0, "completed" => 0, "failed" => 0, "retry" => 0, "skipped" => 0 }
        stats["intake"] = WorkQueue.intake(@db, @settings) if intake
        claims = WorkQueue.claim_batch(@db, @settings, n || @settings.editorial_batch_size)
        stats["claimed"] = claims.size
        claims.map { |c| Thread.new { safe(c) } }.map(&:value).each { |r| stats[r] = stats.fetch(r, 0) + 1 }
        stats
      end

      # Procesa de inmediato un ítem pendiente (POST /process?wait=true). nil si no estaba pendiente.
      def process_now(article_id)
        claim = WorkQueue.claim_one(@db, @settings, article_id)
        claim ? safe(claim) : nil
      end

      def loop_forever
        last_intake = 0.0
        loop do
          busy = false
          begin
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            due = now - last_intake >= @settings.editorial_interval_s
            stats = run_batch(intake: due)
            last_intake = Process.clock_gettime(Process::CLOCK_MONOTONIC) if due
            busy = stats.fetch("claimed", 0) >= @settings.editorial_batch_size
          rescue StandardError => e
            @log.error("Ciclo del worker editorial falló: #{e.class}: #{e.message}")
          end
          sleep(busy ? 1 : @settings.editorial_interval_s)
        end
      end
    end
  end
end
