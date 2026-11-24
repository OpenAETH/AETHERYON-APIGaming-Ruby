# frozen_string_literal: true

require "pg"

module Aetheryon
  LOCK_MIGRATE = 71_010_001 # pg_advisory_xact_lock: serializa migraciones entre procesos
  LOCK_INGEST = 71_010_002  # serializa la ingesta (dedup) entre hilos, procesos e instancias
  LOCK_RUN = 71_010_003     # serializa el alta de una recolección (una sola vigente entre instancias)

  SCHEMA_V1 = <<~'SQL'
    CREATE TABLE IF NOT EXISTS sources(
      key TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, url TEXT,
      enabled INTEGER NOT NULL DEFAULT 1,
      status TEXT NOT NULL DEFAULT 'pending',
      last_sync_at TEXT, last_success_at TEXT, last_error TEXT,
      last_items INTEGER NOT NULL DEFAULT 0, total_items INTEGER NOT NULL DEFAULT 0,
      consecutive_failures INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS games(
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      name TEXT NOT NULL, appid BIGINT, url TEXT,
      platform TEXT NOT NULL DEFAULT 'pc',
      status TEXT NOT NULL DEFAULT 'active',
      resolution TEXT,
      last_sync_at TEXT, last_error TEXT, news_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS ux_games_appid ON games(appid) WHERE appid IS NOT NULL;

    CREATE TABLE IF NOT EXISTS articles(
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL, description TEXT,
      source_key TEXT NOT NULL REFERENCES sources(key),
      url TEXT NOT NULL, canonical_url TEXT NOT NULL,
      published_at TEXT, captured_at TEXT NOT NULL, sort_at TEXT NOT NULL,
      image_url TEXT, author TEXT, external_id TEXT,
      title_key TEXT NOT NULL, game_appid BIGINT,
      original TEXT NOT NULL DEFAULT '{}'
    );
    CREATE INDEX IF NOT EXISTS ix_articles_sort ON articles(sort_at DESC);
    CREATE INDEX IF NOT EXISTS ix_articles_source ON articles(source_key, sort_at DESC);
    CREATE INDEX IF NOT EXISTS ix_articles_title ON articles(title_key);
    CREATE INDEX IF NOT EXISTS ix_articles_game ON articles(game_appid);

    CREATE TABLE IF NOT EXISTS article_refs(
      article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
      source_key TEXT NOT NULL, url TEXT NOT NULL, canonical_url TEXT NOT NULL,
      external_id TEXT, title TEXT, published_at TEXT, captured_at TEXT NOT NULL,
      PRIMARY KEY(article_id, source_key, canonical_url)
    );
    CREATE INDEX IF NOT EXISTS ix_refs_canon ON article_refs(canonical_url);
    CREATE INDEX IF NOT EXISTS ix_refs_ext ON article_refs(source_key, external_id);
    CREATE INDEX IF NOT EXISTS ix_refs_source ON article_refs(source_key);

    CREATE TABLE IF NOT EXISTS classifications(
      article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
      categories TEXT NOT NULL, tags TEXT NOT NULL, platforms TEXT NOT NULL,
      method TEXT NOT NULL, version TEXT NOT NULL, confidence DOUBLE PRECISION NOT NULL, generated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS article_categories(
      article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE, category TEXT NOT NULL,
      PRIMARY KEY(article_id, category)
    );
    CREATE INDEX IF NOT EXISTS ix_cat ON article_categories(category);
    CREATE TABLE IF NOT EXISTS article_platforms(
      article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE, platform TEXT NOT NULL,
      PRIMARY KEY(article_id, platform)
    );
    CREATE INDEX IF NOT EXISTS ix_plat ON article_platforms(platform);

    CREATE TABLE IF NOT EXISTS sync_runs(
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, trigger TEXT NOT NULL,
      started_at TEXT NOT NULL, finished_at TEXT, status TEXT NOT NULL, summary TEXT
    );
    CREATE TABLE IF NOT EXISTS sync_run_sources(
      run_id BIGINT NOT NULL REFERENCES sync_runs(id) ON DELETE CASCADE,
      source_key TEXT NOT NULL, status TEXT NOT NULL,
      fetched INTEGER NOT NULL DEFAULT 0, new INTEGER NOT NULL DEFAULT 0,
      duplicates INTEGER NOT NULL DEFAULT 0, seen INTEGER NOT NULL DEFAULT 0,
      requests INTEGER NOT NULL DEFAULT 0, warnings TEXT, error TEXT, duration_ms INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(run_id, source_key)
    );

    CREATE TABLE IF NOT EXISTS quota_usage(
      provider TEXT NOT NULL, day TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(provider, day)
    );

    CREATE TABLE IF NOT EXISTS http_cache(
      key TEXT PRIMARY KEY, body BYTEA NOT NULL, etag TEXT, last_modified TEXT, fetched_ts DOUBLE PRECISION NOT NULL
    );
  SQL

  SCHEMA_V2 = <<~'SQL'
    -- Cola de procesamiento editorial: un registro por noticia (control de versiones por content_hash + pipeline_version).
    CREATE TABLE IF NOT EXISTS news_queue(
      article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
      status TEXT NOT NULL DEFAULT 'pending',            -- pending | processing | completed | failed
      priority INTEGER NOT NULL DEFAULT 0,
      enqueued_by TEXT NOT NULL,                         -- trending | latest | manual
      content_hash TEXT NOT NULL, pipeline_version TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      enqueued_at TEXT NOT NULL, started_at TEXT, finished_at TEXT,
      next_attempt_at TEXT, lease_until TEXT, last_error TEXT
    );
    CREATE INDEX IF NOT EXISTS ix_queue_pick ON news_queue(status, priority DESC, enqueued_at);
    -- Versión `editorial` de cada noticia (las versiones original y normalized siguen en articles/classifications).
    CREATE TABLE IF NOT EXISTS news_editorial(
      article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
      source_language TEXT NOT NULL, language TEXT NOT NULL DEFAULT 'es', translated INTEGER NOT NULL DEFAULT 0,
      title TEXT NOT NULL, summary TEXT NOT NULL, body TEXT NOT NULL,
      category TEXT NOT NULL, categories TEXT NOT NULL, entities TEXT NOT NULL, uncertainty TEXT NOT NULL,
      insufficient_info INTEGER NOT NULL DEFAULT 0,
      model TEXT NOT NULL, pipeline_version TEXT NOT NULL, content_hash TEXT NOT NULL, generated_at TEXT NOT NULL,
      prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS ix_editorial_lang ON news_editorial(source_language);
    CREATE TABLE IF NOT EXISTS news_editorial_categories(
      article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE, category TEXT NOT NULL,
      PRIMARY KEY(article_id, category)
    );
    CREATE INDEX IF NOT EXISTS ix_editorial_cat ON news_editorial_categories(category);
    -- Registro de consumo del proveedor LLM (una fila por llamada lógica, incluye reintentos HTTP).
    CREATE TABLE IF NOT EXISTS llm_usage(
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      article_id TEXT, model TEXT NOT NULL, status TEXT NOT NULL,   -- ok | rejected | error
      prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0,
      total_tokens INTEGER NOT NULL DEFAULT 0, latency_ms INTEGER NOT NULL DEFAULT 0,
      retries INTEGER NOT NULL DEFAULT 0, error TEXT, created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ix_usage_day ON llm_usage(created_at);
  SQL

  SCHEMA_V3 = <<~'SQL'
    -- Franquicia/IP para agrupar el catálogo sin alterar AppID ni la resolución Steam.
    ALTER TABLE games ADD COLUMN IF NOT EXISTS franchise TEXT;
    UPDATE games SET franchise = CASE
        WHEN appid IN (44310, 44360, 208500, 223670, 226580, 286570, 391040, 515220, 737800, 928600, 1080110, 1134570, 1692250, 2108330, 2488620, 3059520) THEN 'F1'
        WHEN appid IN (24960, 1238830, 1238860, 1238840, 1238810, 1517290, 2807960) THEN 'Battlefield'
        WHEN appid IN (2620, 2630, 7940, 209650, 42700, 1985810, 202970, 209160, 292730, 10180, 42680, 393080, 2640, 1985820, 476600, 10090, 311210, 2000950, 3595230) THEN 'Call of Duty'
        WHEN appid IN (1172470) THEN 'Apex Legends'
        WHEN appid IN (1086940) THEN 'Baldur''s Gate'
        WHEN appid IN (730) THEN 'Counter-Strike'
        WHEN appid IN (1091500) THEN 'Cyberpunk'
        WHEN appid IN (221100) THEN 'DayZ'
        WHEN appid IN (381210) THEN 'Dead by Daylight'
        WHEN appid IN (1422450) THEN 'Deadlock'
        WHEN appid IN (322330) THEN 'Don''t Starve'
        WHEN appid IN (570) THEN 'Dota'
        WHEN appid IN (227300) THEN 'Euro Truck Simulator'
        WHEN appid IN (322170) THEN 'Geometry Dash'
        WHEN appid IN (271590) THEN 'Grand Theft Auto'
        WHEN appid IN (990080) THEN 'Wizarding World'
        WHEN appid IN (477160) THEN 'Human: Fall Flat'
        WHEN appid IN (2767030) THEN 'Marvel'
        WHEN appid IN (578080) THEN 'PUBG'
        WHEN appid IN (1623730) THEN 'Palworld'
        WHEN appid IN (238960) THEN 'Path of Exile'
        WHEN appid IN (108600) THEN 'Project Zomboid'
        WHEN appid IN (1174180) THEN 'Red Dead Redemption'
        WHEN appid IN (252490) THEN 'Rust'
        WHEN appid IN (413150) THEN 'Stardew Valley'
        WHEN appid IN (440) THEN 'Team Fortress'
        WHEN appid IN (105600) THEN 'Terraria'
        WHEN appid IN (489830) THEN 'The Elder Scrolls'
        WHEN appid IN (292030) THEN 'The Witcher'
        WHEN appid IN (359550) THEN 'Rainbow Six'
        WHEN appid IN (892970) THEN 'Valheim'
        WHEN appid IN (236390) THEN 'War Thunder'
        WHEN appid IN (230410) THEN 'Warframe'
        ELSE franchise
    END
    WHERE appid IS NOT NULL;
    CREATE INDEX IF NOT EXISTS ix_games_franchise ON games(franchise);
  SQL

  # (versión, nombre, SQL). Para cambiar el esquema: agregar una entrada nueva al final; nunca editar las aplicadas.
  MIGRATIONS = [[1, "initial", SCHEMA_V1], [2, "editorial_pipeline", SCHEMA_V2], [3, "game_franchises", SCHEMA_V3]].freeze

  # Valor binario (bytea) enviado en formato binario.
  Bytea = Struct.new(:data)

  # Fila con acceso por nombre y por índice (compatible con el uso previo de sqlite3.Row).
  class Row < Hash
    def [](key) = key.is_a?(Integer) ? values[key] : super
  end

  class Cursor
    include Enumerable

    def initialize(result) = @result = result
    def rows = (@rows ||= @result.map { |h| Row[h] })
    def fetchone = rows.first
    def fetchall = rows
    def each(&) = rows.each(&)
    def rowcount = @result.cmd_tuples
  end

  # Envuelve una conexión pg con la interfaz mínima que usa la app: execute/executemany con `?`.
  class Conn
    TOKENS = /'(?:[^']|'')*'|\?/

    def self.translate(sql)
      n = 0
      sql.gsub(TOKENS) { |t| t == "?" ? "$#{n += 1}" : t }
    end

    def initialize(raw) = @raw = raw

    def execute(sql, params = nil)
      return Cursor.new(@raw.exec(sql)) if params.nil?

      Cursor.new(@raw.exec_params(self.class.translate(sql), params.map { |v| encode(v) }))
    end

    def executemany(sql, seq)
      last = nil
      seq.each { |params| last = execute(sql, params) }
      last
    end

    private

    def encode(v)
      case v
      when nil then nil
      when true then "t"
      when false then "f"
      when Bytea then { value: v.data, format: 1 }
      else v.to_s
      end
    end
  end

  TYPE_MAP = PG::TypeMapByOid.new.tap do |tm|
    [[20, "int8"], [21, "int2"], [23, "int4"]].each { |oid, n| tm.add_coder(PG::TextDecoder::Integer.new(oid: oid, name: n)) }
    [[700, "float4"], [701, "float8"]].each { |oid, n| tm.add_coder(PG::TextDecoder::Float.new(oid: oid, name: n)) }
    tm.add_coder(PG::TextDecoder::Bytea.new(oid: 17, name: "bytea"))
    tm.add_coder(PG::TextDecoder::Boolean.new(oid: 16, name: "bool"))
  end

  class Database
    SCHEMA_NAME = /\A[a-z_][a-z0-9_]{0,62}\z/

    attr_reader :url, :schema

    def initialize(url, schema = nil)
      raise "DATABASE_URL no configurada (cadena de conexión PostgreSQL)" if url.nil? || url.empty?
      raise ArgumentError, "Nombre de schema inválido: #{schema.inspect}" if schema && !SCHEMA_NAME.match?(schema)

      @url = url
      @schema = schema
    end

    # Una conexión por bloque (compatible con pgbouncer: sin prepared statements ni locks de sesión).
    # Commit al salir normalmente (incluye return/break); rollback si hay excepción.
    def conn
      kw = { connect_timeout: 10 }
      kw[:options] = "-c search_path=#{@schema}" if @schema
      raw = PG.connect(@url, **kw)
      raw.type_map_for_results = TYPE_MAP
      raw.set_client_encoding("UTF8")
      raw.set_notice_processor { |_msg| } # sin ruido por CREATE ... IF NOT EXISTS
      ok = true
      begin
        raw.exec("BEGIN")
        yield Conn.new(raw)
      rescue Exception # rubocop:disable Lint/RescueException
        ok = false
        raise
      ensure
        begin
          raw.exec(ok ? "COMMIT" : "ROLLBACK") unless raw.finished?
        rescue PG::Error
          nil
        end
        raw.close unless raw.finished?
      end
    end

    # Aplica las migraciones pendientes (idempotente, serializado). Devuelve las versiones aplicadas.
    def migrate
      applied = []
      conn do |c|
        c.execute("SELECT pg_advisory_xact_lock(?)", [LOCK_MIGRATE])
        c.execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)")
        done = c.execute("SELECT version FROM schema_migrations").map { |r| r["version"] }
        MIGRATIONS.each do |version, name, sql|
          next if done.include?(version)

          c.execute(sql)
          c.execute("INSERT INTO schema_migrations(version, name, applied_at) VALUES(?,?,?)", [version, name, Util.utcnow_iso])
          applied << version
        end
      end
      applied
    end

    # Marca como interrumpidas las recolecciones que quedaron 'running' (solo con una instancia única).
    def reset_interrupted_runs
      conn { |c| c.execute("UPDATE sync_runs SET status='interrupted', finished_at=? WHERE status='running'", [Util.utcnow_iso]) }
    end

    def init
      migrate
      reset_interrupted_runs
    end

    # ---- caché HTTP (la clave es lógica: nunca contiene credenciales) ----
    def cache_get(key) = conn { |c| c.execute("SELECT * FROM http_cache WHERE key=?", [key]).fetchone }

    def cache_put(key, body, etag, last_modified)
      conn do |c|
        c.execute(
          "INSERT INTO http_cache(key, body, etag, last_modified, fetched_ts) VALUES(?,?,?,?,?) " \
          "ON CONFLICT(key) DO UPDATE SET body=excluded.body, etag=excluded.etag, " \
          "last_modified=excluded.last_modified, fetched_ts=excluded.fetched_ts",
          [key, Bytea.new(body), etag, last_modified, Time.now.to_f]
        )
      end
    end

    def cache_touch(key) = conn { |c| c.execute("UPDATE http_cache SET fetched_ts=? WHERE key=?", [Time.now.to_f, key]) }

    # ---- juegos (usado por el adaptador Steam) ----
    def games_for_sync(limit)
      conn do |c|
        c.execute("SELECT * FROM games WHERE status='active' AND appid IS NOT NULL ORDER BY COALESCE(last_sync_at,'') ASC LIMIT ?", [limit]).fetchall
      end
    end

    def mark_game_synced(game_id, count, error)
      conn { |c| c.execute("UPDATE games SET last_sync_at=?, last_error=?, news_count=news_count+? WHERE id=?", [Util.utcnow_iso, error, count, game_id]) }
    end
  end
end
