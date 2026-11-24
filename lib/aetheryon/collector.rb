# frozen_string_literal: true

require "timeout"

module Aetheryon
  class AlreadyRunning < StandardError; end

  class SourceTimeout < Timeout::Error; end

  # Recolector central: ejecuta cada fuente de forma aislada y concurrente (un hilo por fuente), registra todo.
  class Collector
    attr_reader :db, :settings, :adapters, :quota, :thread

    def initialize(db, settings, adapters, client_getter)
      @db = db
      @settings = settings
      @adapters = adapters
      @client_getter = client_getter
      @quota = QuotaManager.new(db)
      @mutex = Mutex.new
      @running = false
      @thread = nil
      @log = Aetheryon.log("collector")
    end

    def stale_cutoff = Util.iso(Util.utcnow - settings.stale_run_min * 60, timespec: "seconds")

    def running?
      return true if @mutex.synchronize { @running }

      db.conn { |c| !c.execute("SELECT 1 FROM sync_runs WHERE status='running' AND started_at>?", [stale_cutoff]).fetchone.nil? }
    end
    alias is_running running?

    # Crea la ejecución si no hay otra vigente (en esta u otra instancia). Atómico vía advisory lock.
    def begin_run(trigger)
      db.conn do |c|
        c.execute("SELECT pg_advisory_xact_lock(?)", [LOCK_RUN])
        c.execute("UPDATE sync_runs SET status='interrupted', finished_at=? WHERE status='running' AND started_at<=?",
                  [Util.utcnow_iso, stale_cutoff])
        if c.execute("SELECT 1 FROM sync_runs WHERE status='running'").fetchone
          nil
        else
          c.execute("INSERT INTO sync_runs(trigger, started_at, status) VALUES(?,?,'running') RETURNING id", [trigger, Util.utcnow_iso]).fetchone["id"]
        end
      end
    end

    def source_state
      rows = db.conn { |c| c.execute("SELECT key, enabled, last_sync_at FROM sources").fetchall }
      [rows.to_h { |r| [r["key"], r["enabled"] != 0] }, rows.to_h { |r| [r["key"], r["last_sync_at"]] }]
    end

    def finish_run(run_id, status, summary)
      db.conn { |c| c.execute("UPDATE sync_runs SET status=?, finished_at=?, summary=? WHERE id=?", [status, Util.utcnow_iso, summary, run_id]) }
    end

    # Inicia una recolección en segundo plano. Devuelve el id de ejecución.
    def start(trigger: "manual", only: nil, force: true) = start_with_thread(trigger, only, force).first

    def run(trigger: "manual", only: nil, force: true)
      run_id, th = start_with_thread(trigger, only, force)
      th.join
      get_run(run_id)
    end

    def start_with_thread(trigger, only, force)
      @mutex.synchronize do
        raise AlreadyRunning, "Ya hay una recolección en curso" if @running

        @running = true
      end
      begin
        run_id = begin_run(trigger)
        raise AlreadyRunning, "Ya hay una recolección en curso" if run_id.nil? # otra instancia tiene una recolección vigente
      rescue Exception # rubocop:disable Lint/RescueException
        @mutex.synchronize { @running = false }
        raise
      end
      th = Thread.new do
        Thread.current.report_on_exception = false
        execute(run_id, trigger, only, force)
      end
      @thread = th
      [run_id, th]
    end

    def execute(run_id, _trigger, only, force)
      ctx = AdapterContext.new(@client_getter.call, db, settings, quota, force)
      enabled, last = source_state
      selected = adapters.select { |a| only.nil? || only.empty? || only.include?(a.key) }
      threads = selected.map do |a|
        Thread.new do
          Thread.current.report_on_exception = false
          run_source(run_id, a, ctx, enabled.fetch(a.key, true), last[a.key], force)
        end
      end
      results = threads.map(&:value)
      attempted = results.select { |r| %w[ok degraded error].include?(r["status"]) }
      errors = attempted.select { |r| r["status"] == "error" }
      status = errors.empty? ? "success" : (errors.size == attempted.size ? "failed" : "partial")
      summary = { "sources" => results.size, "new" => results.sum { |r| r["new"] }, "duplicates" => results.sum { |r| r["duplicates"] },
                  "errors" => errors.map { |r| r["source"] } }
      finish_run(run_id, status, JSON.generate(summary))
    rescue StandardError => e
      @log.error("Recolección #{run_id} abortada: #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
      finish_run(run_id, "failed", nil)
    ensure
      @mutex.synchronize { @running = false }
    end

    def due?(adapter, last_sync)
      return true if last_sync.nil? || last_sync.empty?

      Util.utcnow - Util.parse_iso(last_sync) >= adapter.min_interval_min(settings) * 60
    end

    def run_source(run_id, a, ctx, enabled, last_sync, force)
      r = { "source" => a.key, "status" => "ok", "fetched" => 0, "new" => 0, "duplicates" => 0, "seen" => 0,
            "requests" => 0, "warnings" => [], "error" => nil, "duration_ms" => 0 }
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      src_update = nil
      begin
        reason = a.availability(settings)
        if !enabled
          r["status"] = "paused"
        elsif reason
          r["status"] = "blocked"
          r["error"] = reason
          src_update = ["blocked", reason]
        elsif !force && !due?(a, last_sync)
          r["status"] = "skipped"
        else
          res = Timeout.timeout(settings.source_timeout, SourceTimeout) { a.fetch(ctx) }
          stats = Store.ingest(db, res.items)
          r.merge!("fetched" => res.items.size, "new" => stats.new, "duplicates" => stats.duplicates, "seen" => stats.seen,
                   "requests" => res.requests_made, "warnings" => res.warnings)
          r["status"] = res.warnings.empty? ? "ok" : "degraded"
        end
      rescue SourceUnavailable => e
        r["status"] = e.status
        r["error"] = Aetheryon.redact(e.message, settings.secrets)
        src_update = [r["status"], r["error"]]
      rescue Timeout::Error
        r["status"] = "error"
        r["error"] = "Timeout tras #{settings.source_timeout.round}s"
      rescue AdapterError => e
        r["status"] = "error"
        r["error"] = Aetheryon.redact(e.message, settings.secrets)
      rescue StandardError => e # un bug en un adaptador no debe tumbar a los demás
        @log.error("Adaptador #{a.key} falló: #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
        r["status"] = "error"
        r["error"] = "Error interno: #{e.class.name.split('::').last}"
      end
      r["duration_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
      record(run_id, a.key, r, src_update)
      r
    end

    def record(run_id, key, r, src_update)
      db.conn do |c|
        c.execute(
          "INSERT INTO sync_run_sources(run_id, source_key, status, fetched, new, duplicates, seen, requests, warnings, error, duration_ms) " \
          "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
          [run_id, key, r["status"], r["fetched"], r["new"], r["duplicates"], r["seen"], r["requests"],
           JSON.generate(r["warnings"]), r["error"], r["duration_ms"]]
        )
        now = Util.utcnow_iso
        st = r["status"]
        if %w[ok degraded].include?(st)
          warn_txt = r["warnings"].join("; ")[0, 500]
          c.execute("UPDATE sources SET status=?, last_sync_at=?, last_success_at=?, last_error=?, last_items=?, " \
                    "total_items=total_items+?, consecutive_failures=0 WHERE key=?",
                    [st, now, now, warn_txt.to_s.empty? ? nil : warn_txt, r["fetched"], r["new"], key])
        elsif st == "error"
          c.execute("UPDATE sources SET status='error', last_sync_at=?, last_error=?, consecutive_failures=consecutive_failures+1 WHERE key=?",
                    [now, r["error"], key])
        elsif src_update
          c.execute("UPDATE sources SET status=?, last_error=? WHERE key=?", [src_update[0], src_update[1], key])
        elsif st == "paused"
          c.execute("UPDATE sources SET status='paused' WHERE key=?", [key])
        end
      end
    end

    # Devuelve el detalle de una ejecución o nil si no existe.
    def get_run(run_id)
      db.conn do |c|
        run = c.execute("SELECT * FROM sync_runs WHERE id=?", [run_id]).fetchone
        return nil unless run

        srcs = c.execute("SELECT * FROM sync_run_sources WHERE run_id=? ORDER BY source_key", [run_id]).fetchall
        out = run.to_h
        out["summary"] = run["summary"] ? JSON.parse(run["summary"]) : nil
        out["sources"] = srcs.map { |s| s.to_h.merge("warnings" => JSON.parse(s["warnings"] || "[]")) }
        out
      end
    end

    def scheduler_loop
      sleep settings.scheduler_initial_delay_s
      loop do
        begin
          run(trigger: "scheduled", force: false)
        rescue AlreadyRunning
          nil
        rescue StandardError => e
          @log.error("Scheduler: error inesperado: #{e.class}: #{e.message}")
        end
        sleep settings.collect_interval_min * 60
      end
    end
  end
end
