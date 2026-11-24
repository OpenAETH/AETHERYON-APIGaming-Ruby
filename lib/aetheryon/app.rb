# frozen_string_literal: true

require "sinatra/base"
require "rack/builder"

module Aetheryon
  Context = Struct.new(:settings, :db, :client, :collector, :editorial, :steam)

  # Inyecta el contexto (config, DB, colector, worker) en cada request.
  class ContextMiddleware
    def initialize(app, ctx)
      @app = app
      @ctx = ctx
    end

    def call(env)
      env["aeth.ctx"] = @ctx
      @app.call(env)
    end
  end

  module Helpers
    def ctx = env["aeth.ctx"]
    def db = ctx.db
    def cfg = ctx.settings

    def json(obj, code = 200)
      status code
      headers "Content-Type" => "application/json"
      JSON.generate(obj)
    end

    def query = @query ||= Validation::Params.new(request.query_string)

    def raw_body
      b = request.body.read
      request.body.rewind
      b
    end

    # Protege operaciones de escritura. Sin ADMIN_API_KEY: abierto en desarrollo, cerrado en producción.
    def require_admin!
      s = cfg
      if s.admin_api_key.to_s.empty?
        raise HTTPError.new(503, "ADMIN_API_KEY no configurada: escritura deshabilitada en producción") if s.app_env == "production"

        return
      end
      key = request.env["HTTP_X_API_KEY"].to_s
      return unless key.empty? || !Rack::Utils.secure_compare(key, s.admin_api_key)

      raise HTTPError.new(401, "API key inválida o ausente (header X-API-Key)")
    end

    def require_cron!
      secret = cfg.cron_secret
      raise HTTPError.new(503, "CRON_SECRET no configurada: endpoints de cron deshabilitados") if secret.to_s.empty?

      auth = request.env["HTTP_AUTHORIZATION"].to_s
      return unless auth.empty? || !Rack::Utils.secure_compare(auth, "Bearer #{secret}")

      raise HTTPError.new(401, "Credencial de cron inválida (header Authorization: Bearer <CRON_SECRET>)")
    end

    def path_int(name)
      v = params[name].to_s
      n = Validation.parse_int(v)
      raise ValidationFailed, [Validation.err("int_parsing", ["path", name], "Input should be a valid integer, unable to parse string as an integer", v)] if n.nil?

      n
    end

    def check_categories!(category)
      bad = (category || []).reject { |c| Classifier::CATEGORIES.include?(c) }
      return if bad.empty?

      raise HTTPError.new(422, "Categorías desconocidas: #{Util.py_list_repr(bad)}. Válidas: #{Util.py_list_repr(Classifier::CATEGORIES)}")
    end

    def iso_or_nil(t) = t && Util.iso(t)

    def news_filters(source, category, platform, game, date_from, date_to, q = nil)
      check_categories!(category)
      Repository::Filters.new(sources: source || [], categories: category || [], platforms: (platform || []).map(&:downcase),
                              game: game, date_from: iso_or_nil(date_from), date_to: iso_or_nil(date_to), q: q)
    end

    # response_model=Article: se completa `score` (null si no es tendencia)
    def article_out(a) = a.key?("score") ? a : a.merge("score" => nil)
    def page_out(pg) = pg.merge("items" => pg["items"].map { |a| article_out(a) })
  end

  module Routes
    module Pipeline
      def self.registered(app)
        app.get "/api/news/processed" do
          q = query
          source = q.list("source")
          category = q.list("category")
          language = q.list("language")
          date_from = q.datetime("date_from")
          date_to = q.datetime("date_to")
          page = q.int("page", default: 1, ge: 1)
          page_size = q.int("page_size", default: 20, ge: 1, le: 100)
          q.finish!
          check_categories!(category)
          f = Editorial::Processed::ProcessedFilters.new(sources: source || [], categories: category || [],
                                                         languages: (language || []).map(&:downcase),
                                                         date_from: iso_or_nil(date_from), date_to: iso_or_nil(date_to))
          json Editorial::Processed.list_processed(db, f, page, page_size)
        end

        app.get "/api/news/es" do
          q = query
          source = q.list("source")
          category = q.list("category")
          translated = q.bool("translated")
          date_from = q.datetime("date_from")
          date_to = q.datetime("date_to")
          page = q.int("page", default: 1, ge: 1)
          page_size = q.int("page_size", default: 20, ge: 1, le: 100)
          q.finish!
          check_categories!(category)
          f = Editorial::Processed::ProcessedFilters.new(sources: source || [], categories: category || [], translated: translated,
                                                         date_from: iso_or_nil(date_from), date_to: iso_or_nil(date_to))
          pg = Editorial::Processed.list_processed(db, f, page, page_size)
          json pg.merge("items" => pg["items"].map { |i| Editorial::Processed.flatten_es(i) }, "pending" => Editorial::Processed.pending_count(db))
        end

        app.get "/api/news/queue" do
          q = query
          status_ = q.literal("status", Editorial::WorkQueue::STATUSES)
          page = q.int("page", default: 1, ge: 1)
          page_size = q.int("page_size", default: 20, ge: 1, le: 100)
          q.finish!
          json Editorial::WorkQueue.queue_page(db, cfg, status_, page, page_size)
        end

        app.post "/api/news/:article_id/process" do
          require_admin!
          q = query
          force = q.bool("force", default: false)
          wait = q.bool("wait", default: false)
          q.finish!
          article_id = params["article_id"]
          worker = ctx.editorial
          raise HTTPError.new(503, "GROQ_API_KEY no configurada: el procesamiento editorial está deshabilitado") unless worker.enabled?

          art = Repository.get_article(db, article_id)
          raise HTTPError.new(404, "Noticia no encontrada") unless art

          Editorial::WorkQueue.enqueue(db, [art], "manual", 100, force)
          worker.process_now(article_id) if wait
          item = Editorial::WorkQueue.get_item(db, cfg, article_id)
          json item, %w[completed failed].include?(item["status"]) ? 200 : 202
        end
      end
    end

    module News
      def self.registered(app)
        app.get "/api/news" do
          q = query
          source = q.list("source")
          category = q.list("category")
          platform = q.list("platform")
          game = q.int("game")
          date_from = q.datetime("date_from")
          date_to = q.datetime("date_to")
          page = q.int("page", default: 1, ge: 1)
          page_size = q.int("page_size", default: 20, ge: 1, le: 100)
          q.finish!
          json page_out(Repository.list_articles(db, news_filters(source, category, platform, game, date_from, date_to), page, page_size))
        end

        app.get "/api/news/latest" do
          q = query
          source = q.list("source")
          category = q.list("category")
          platform = q.list("platform")
          game = q.int("game")
          hours = q.int("hours", default: 48, ge: 1, le: 24 * 30)
          page = q.int("page", default: 1, ge: 1)
          page_size = q.int("page_size", default: 20, ge: 1, le: 100)
          q.finish!
          since = Util.utcnow - hours * 3600
          json page_out(Repository.list_articles(db, news_filters(source, category, platform, game, since, nil), page, page_size))
        end

        app.get "/api/news/trending" do
          q = query
          hours = q.int("hours", default: 48, ge: 1, le: 24 * 7)
          limit = q.int("limit", default: 20, ge: 1, le: 100)
          category = q.list("category")
          platform = q.list("platform")
          q.finish!
          json Repository.trending(db, hours, limit, news_filters(nil, category, platform, nil, nil, nil)).map { |a| article_out(a) }
        end

        app.get "/api/news/search" do
          q = query
          text = q.str("q", required: true, min: 2, max: 100)
          source = q.list("source")
          category = q.list("category")
          platform = q.list("platform")
          game = q.int("game")
          date_from = q.datetime("date_from")
          date_to = q.datetime("date_to")
          page = q.int("page", default: 1, ge: 1)
          page_size = q.int("page_size", default: 20, ge: 1, le: 100)
          q.finish!
          json page_out(Repository.list_articles(db, news_filters(source, category, platform, game, date_from, date_to, text), page, page_size))
        end

        app.get "/api/news/:article_id" do
          a = Repository.get_article(db, params["article_id"])
          raise HTTPError.new(404, "Noticia no encontrada") unless a

          json article_out(a)
        end
      end
    end

    module Games
      def self.registered(app)
        app.helpers do
          def game_row(c, gid)
            r = c.execute("SELECT * FROM games WHERE id=?", [gid]).fetchone
            raise HTTPError.new(404, "Juego no encontrado") unless r

            r.to_h
          end
        end

        app.get "/api/games/franchises" do
          rows = db.conn do |c|
            c.execute("SELECT franchise AS name, COUNT(*) AS count FROM games WHERE franchise IS NOT NULL AND franchise<>'' " \
                      "GROUP BY franchise ORDER BY franchise").fetchall
          end
          json rows.map(&:to_h)
        end

        app.get "/api/games" do
          q = query
          st = q.str("status", pattern: /\A(active|paused|unresolved)\z/)
          fr = q.str("franchise", min: 1, max: 100)
          q.finish!
          db.conn do |c|
            sql = +"SELECT * FROM games"
            conds = []
            p = []
            if st && !st.empty?
              conds << "status=?"
              p << st
            end
            if fr && !fr.empty?
              if fr.downcase(:fold) == "unassigned"
                conds << "(franchise IS NULL OR franchise='')"
              else
                conds << "LOWER(franchise)=LOWER(?)"
                p << Util.py_strip(fr)
              end
            end
            sql << " WHERE #{conds.join(' AND ')}" unless conds.empty?
            json c.execute("#{sql} ORDER BY name", p).map(&:to_h)
          end
        end

        app.get "/api/games/steam-search" do
          q = query
          text = q.str("q", required: true, min: 2)
          q.finish!
          begin
            found, = ctx.steam.search(text)
          rescue RuntimeError => e
            raise HTTPError.new(503, "#{e.message}. Cargá el AppID manualmente.")
          end
          json found
        end

        app.get "/api/games/:game_id" do
          gid = path_int("game_id")
          json db.conn { |c| game_row(c, gid) }
        end

        app.post "/api/games" do
          body = Validation.parse_body(raw_body, required: true)
          require_admin!
          data = Validation.game_model(body, create: true)
          appid = data["appid"]
          method = appid ? "manual" : nil
          candidates = []
          appid, method, candidates = ctx.steam.resolve(name: data["name"], url: data["url"]) unless appid
          status_ = appid ? data["status"] : "unresolved"
          now = Util.utcnow_iso
          begin
            game = db.conn do |c|
              gid = c.execute(
                "INSERT INTO games(name, appid, url, platform, status, resolution, franchise, created_at, updated_at) " \
                "VALUES(?,?,?,?,?,?,?,?,?) RETURNING id",
                [data["name"], appid, data["url"], data["platform"].downcase, status_, method, data["franchise"], now, now]
              ).fetchone["id"]
              game_row(c, gid)
            end
          rescue PG::UniqueViolation
            raise HTTPError.new(409, "Ya existe un juego con AppID #{appid}")
          end
          json game.merge("resolved" => !appid.nil?, "candidates" => appid ? [] : candidates), 201
        end

        app.patch "/api/games/:game_id" do
          body = Validation.parse_body(raw_body, required: true)
          require_admin!
          gid = path_int("game_id")
          data = Validation.game_model(body, create: false)
          db.conn do |c|
            cur = game_row(c, gid)
            res = nil
            if data.key?("url") && !Util.truthy?(data["appid"]) && (a = SteamCatalog.appid_from_url(data["url"]))
              data["appid"] = a
              res = "url"
            end
            if Util.truthy?(data["appid"])
              res ||= "manual"
              data["status"] = "active" if cur["status"] == "unresolved" && !data.key?("status")
            end
            sets = data.dup
            sets["platform"] = sets["platform"].downcase if sets.key?("platform")
            sets["resolution"] = res if res
            unless sets.empty?
              cols = sets.keys.map { |k| "#{k}=?" }.join(", ")
              begin
                c.execute("UPDATE games SET #{cols}, updated_at=? WHERE id=?", [*sets.values, Util.utcnow_iso, gid])
              rescue PG::UniqueViolation
                raise HTTPError.new(409, "Ese AppID ya está registrado en otro juego")
              end
            end
            json game_row(c, gid)
          end
        end

        app.post "/api/games/:game_id/resolve" do
          require_admin!
          gid = path_int("game_id")
          g = db.conn { |c| game_row(c, gid) }
          appid, method, candidates = ctx.steam.resolve(name: g["name"], url: g["url"])
          if appid
            begin
              db.conn { |c| c.execute("UPDATE games SET appid=?, status='active', resolution=?, updated_at=? WHERE id=?", [appid, method, Util.utcnow_iso, gid]) }
            rescue PG::UniqueViolation
              raise HTTPError.new(409, "Ese AppID ya está registrado en otro juego")
            end
          end
          json({ "resolved" => !appid.nil?, "appid" => appid, "method" => method, "candidates" => candidates })
        end

        app.delete "/api/games/:game_id" do
          require_admin!
          gid = path_int("game_id")
          db.conn do |c|
            game_row(c, gid)
            c.execute("DELETE FROM games WHERE id=?", [gid])
          end
          status 204
          body ""
        end
      end
    end

    module Ops
      def self.registered(app)
        app.helpers do
          def adapter_for(key)
            ctx.collector.adapters.find { |a| a.key == key } or raise HTTPError.new(404, "Fuente desconocida: #{key}")
          end

          def set_enabled(key, enabled)
            adapter_for(key)
            db.conn do |c|
              c.execute("UPDATE sources SET enabled=?, status=CASE WHEN ?=1 THEN 'pending' ELSE 'paused' END WHERE key=?",
                        [enabled ? 1 : 0, enabled ? 1 : 0, key])
            end
            { "key" => key, "enabled" => enabled }
          end
        end

        app.get "/health" do
          db.conn { |c| c.execute("SELECT 1") }
          json({ "status" => "ok" })
        end

        app.get("/api/categories") { json Repository.categories(db) }

        app.get "/api/sources" do
          adapters = ctx.collector.adapters.to_h { |a| [a.key, a] }
          out = Repository.sources(db).map do |s|
            a = adapters[s["key"]]
            s["unavailable_reason"] = a ? a.availability(cfg) : nil
            s["min_interval_min"] = a ? a.min_interval_min(cfg) : nil
            if s["key"] == "newsmesh"
              s["quota"] = { "used_today" => ctx.collector.quota.used("newsmesh"), "daily_limit" => cfg.newsmesh_daily_limit,
                             "reserve" => cfg.newsmesh_quota_reserve }
            end
            s
          end
          json out
        end

        app.post("/api/sources/:key/pause") { require_admin!; json set_enabled(params["key"], false) }
        app.post("/api/sources/:key/enable") { require_admin!; json set_enabled(params["key"], true) }

        # Ejecuta el adaptador y devuelve una muestra. No persiste nada. En NewsMesh consume cuota si no hay caché vigente.
        app.post "/api/sources/:key/test" do
          require_admin!
          key = params["key"]
          a = adapter_for(key)
          reason = a.availability(cfg)
          next json({ "ok" => false, "status" => "blocked", "error" => reason }) if reason

          c = AdapterContext.new(ctx.client, db, cfg, ctx.collector.quota, true)
          begin
            res = Timeout.timeout(cfg.source_timeout, SourceTimeout) { a.fetch(c) }
          rescue SourceUnavailable => e
            next json({ "ok" => false, "status" => e.status, "error" => Aetheryon.redact(e.message, cfg.secrets) })
          rescue Timeout::Error
            next json({ "ok" => false, "status" => "error", "error" => "Timeout" })
          rescue AdapterError => e
            next json({ "ok" => false, "status" => "error", "error" => Aetheryon.redact(e.message.empty? ? "Timeout" : e.message, cfg.secrets) })
          rescue StandardError => e # el test de una fuente nunca debe devolver 500
            Aetheryon.log("ops").error("test_source(#{key}) falló: #{e.class}: #{e.message}")
            next json({ "ok" => false, "status" => "error", "error" => Aetheryon.redact("Error interno: #{e.class.name.split('::').last}: #{e.message}", cfg.secrets) })
          end
          json({ "ok" => true, "fetched" => res.items.size, "requests" => res.requests_made, "warnings" => res.warnings,
                 "sample" => res.items.first(3).map { |i| { "title" => i.title, "url" => i.url, "published_at" => i.published_at && Util.iso(i.published_at) } } })
        end

        app.post "/api/collect" do
          body = Validation.parse_body(raw_body, required: false)
          require_admin!
          req = Validation.collect_request(body)
          col = ctx.collector
          known = col.adapters.map(&:key)
          unknown = (req["sources"] || []).reject { |k| known.include?(k) }
          raise HTTPError.new(422, "Fuentes desconocidas: #{Util.py_list_repr(unknown)}") unless unknown.empty?

          # En serverless las tareas en segundo plano se congelan al responder: la recolección corre en línea (200 con el resultado).
          inline = cfg.serverless
          run = nil
          begin
            if inline
              run = col.run(trigger: "manual", only: req["sources"], force: req["force"])
              run_id = run["id"]
            else
              run_id = col.start(trigger: "manual", only: req["sources"], force: req["force"])
            end
          rescue AlreadyRunning
            raise HTTPError.new(409, "Ya hay una recolección en curso")
          end
          out = { "run_id" => run_id, "status" => inline ? run["status"] : "running", "status_url" => "/api/sync/runs/#{run_id}" }
          inline ? json(out.merge("run" => run), 200) : json(out, 202)
        end

        app.get "/api/sync/status" do
          col = ctx.collector
          last, total = db.conn do |c|
            [c.execute("SELECT id FROM sync_runs ORDER BY id DESC LIMIT 1").fetchone, c.execute("SELECT COUNT(*) FROM articles").fetchone[0]]
          end
          json({ "running" => col.running?, "total_articles" => total, "scheduler_enabled" => cfg.scheduler_enabled,
                 "last_run" => last ? col.get_run(last["id"]) : nil })
        end

        app.get "/api/sync/runs" do
          q = query
          limit = q.int("limit", default: 20, ge: 1, le: 100)
          q.finish!
          ids = db.conn { |c| c.execute("SELECT id FROM sync_runs ORDER BY id DESC LIMIT ?", [limit]).map { |r| r["id"] } }
          json ids.map { |i| ctx.collector.get_run(i) }
        end

        app.get "/api/sync/runs/:run_id" do
          run = ctx.collector.get_run(path_int("run_id"))
          raise HTTPError.new(404, "Ejecución no encontrada") unless run

          json run
        end
      end
    end

    # Endpoints para schedulers externos (Vercel Cron, GitHub Actions, cron-job.org). Autenticados con CRON_SECRET.
    module Cron
      def self.registered(app)
        process = lambda do
          require_cron!
          q = query
          batch = q.int("batch", ge: 1, le: 20)
          q.finish!
          w = ctx.editorial
          next json({ "ok" => true, "skipped" => "groq_not_configured" }) unless w.enabled?

          json({ "ok" => true }.merge(w.run_batch(n: batch)))
        end
        collect = lambda do
          require_cron!
          q = query
          source = q.list("source")
          force = q.bool("force", default: false)
          q.finish!
          col = ctx.collector
          known = col.adapters.map(&:key)
          unknown = (source || []).reject { |k| known.include?(k) }
          raise HTTPError.new(422, "Fuentes desconocidas: #{Util.py_list_repr(unknown)}") unless unknown.empty?

          begin
            run = col.run(trigger: "cron", only: source, force: force)
          rescue AlreadyRunning
            next json({ "ok" => true, "skipped" => "already_running" })
          end
          ok = run["status"] != "failed"
          json({ "ok" => ok, "run" => run }, ok ? 200 : 502)
        end
        %i[get post].each do |verb|
          app.public_send(verb, "/api/cron/process", &process)
          app.public_send(verb, "/api/cron/collect", &collect)
        end
      end
    end
  end

  class Base < Sinatra::Base
    PANEL = File.join(__dir__, "static", "panel.html")

    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, false
    set :logging, false
    set :protection, false
    set :static, false
    set :sessions, false
    set :x_cascade, false
    set :host_authorization, { permitted_hosts: [] }

    helpers Helpers

    error(HTTPError) do
      e = env["sinatra.error"]
      json({ "detail" => e.detail }, e.status)
    end

    error(ValidationFailed) { json({ "detail" => env["sinatra.error"].errors }, 422) }

    error(StandardError) do
      e = env["sinatra.error"]
      Aetheryon.log("app").error("#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      status 500
      headers "Content-Type" => "text/plain; charset=utf-8"
      "Internal Server Error"
    end

    not_found do
      allow = OpenAPI.route_table.select { |_, path, _| Regexp.new("\\A#{Regexp.escape(path).gsub(/\\\{[^}]+\\\}/, '[^/]+')}\\z").match?(request.path_info) }.map(&:first)
      if allow.empty? || allow.include?(request.request_method)
        json({ "detail" => "Not Found" }, 404)
      else
        headers "Allow" => allow.uniq.sort.join(", ")
        json({ "detail" => "Method Not Allowed" }, 405)
      end
    end

    # El orden de registro es contractual: rutas estáticas antes de /api/news/:article_id y /api/games/:game_id.
    register Routes::Pipeline, Routes::News, Routes::Games, Routes::Ops, Routes::Cron

    get("/panel") { headers "Content-Type" => "text/html; charset=utf-8"; File.binread(PANEL) }
    get("/") { status 307; headers "Location" => "/docs"; "" }
    get("/docs") { headers "Content-Type" => "text/html; charset=utf-8"; OpenAPI.swagger_html }
    get("/redoc") { headers "Content-Type" => "text/html; charset=utf-8"; OpenAPI.redoc_html }
    get("/openapi.json") { json OpenAPI.build }
  end

  # Aplicación Rack: arma el contexto (DB, adaptadores, colector, worker editorial) y monta los middlewares.
  class Application
    attr_reader :ctx

    def initialize(settings = nil, client: nil)
      settings ||= Settings.from_env
      db = Database.new(settings.database_url, settings.db_schema)
      db.init unless settings.serverless # en serverless las migraciones corren en el deploy: `rake migrate`
      adapters = Registry.build_adapters
      Registry.sync_sources_table(db, adapters)
      http = client || HttpClient.new(timeout: settings.http_timeout, user_agent: settings.user_agent)
      getter = -> { @ctx.client }
      @ctx = Context.new(settings, db, http, nil, nil, nil)
      @ctx.collector = Collector.new(db, settings, adapters, getter)
      @ctx.editorial = Editorial::Worker.new(db, settings, getter)
      @ctx.steam = SteamCatalog.new(getter, settings.data_dir)
      @threads = []
      c = @ctx
      origins = settings.cors_origins
      @app = Rack::Builder.new do
        use Cors, origins unless origins.empty?
        use ContextMiddleware, c
        run Base
      end.to_app
    end

    def call(env) = @app.call(env)

    def openapi = OpenAPI.build

    # Equivale al lifespan de FastAPI: arranca el scheduler y el worker editorial (si corresponde).
    def start!
      s = ctx.settings
      log = Aetheryon.log("editorial")
      @threads << Thread.new { ctx.collector.scheduler_loop } if s.scheduler_enabled
      if s.editorial_worker_enabled && ctx.editorial.enabled?
        @threads << Thread.new { ctx.editorial.loop_forever }
      end
      if !ctx.editorial.enabled?
        log.warn("Pipeline editorial DESHABILITADO: define GROQ_API_KEY para traducir noticias al español")
      else
        log.info("Pipeline editorial: #{s.editorial_worker_enabled ? 'worker activo' : 'worker apagado (usar /api/cron/process)'} (modelo #{s.groq_model})")
      end
      self
    end

    def shutdown!
      @threads.each(&:kill)
      @threads.clear
    end
  end
end
