# frozen_string_literal: true

module Aetheryon
  DEFAULTS = {
    app_env: "development", serverless: false, database_url: "", db_schema: nil, data_dir: "./data",
    admin_api_key: nil, cron_secret: nil, stale_run_min: 20,
    groq_api_key: nil, groq_base_url: "https://api.groq.com/openai/v1", groq_model: "llama-3.3-70b-versatile",
    groq_temperature: 0.2, groq_max_tokens: 1200, groq_timeout: 45.0, groq_concurrency: 2, groq_max_rpm: 30,
    groq_max_retries: 3, editorial_max_attempts: 3, editorial_batch_size: 5, editorial_worker_enabled: true,
    editorial_interval_s: 60, editorial_intake_hours: 48, editorial_trending_limit: 20, editorial_latest_limit: 50,
    editorial_lease_min: 10, user_agent: "AETHERYON-GamingNewsAPI/1.0", cors_origins: [], http_timeout: 20.0,
    source_timeout: 90.0, scheduler_enabled: true, collect_interval_min: 15, scheduler_initial_delay_s: 15,
    rss_min_interval_min: 30, steam_min_interval_min: 60, steam_news_count: 10, steam_max_games_per_run: 50,
    newsmesh_api_key: nil, newsmesh_plan: "free", newsmesh_base_url: "https://api.newsmesh.co/v1",
    newsmesh_endpoint: "/search", newsmesh_query_param: "q", newsmesh_limit_param: "limit",
    newsmesh_auth_mode: "query", newsmesh_auth_name: "apiKey", newsmesh_queries: ["video games", "gaming industry"],
    newsmesh_per_request: 10, newsmesh_daily_limit: 25, newsmesh_quota_reserve: 3, newsmesh_min_interval_min: 240
  }.freeze

  # Configuración centralizada (inmutable). `with(**cambios)` equivale a dataclasses.replace.
  class Settings < Struct.new(*DEFAULTS.keys, keyword_init: true)
    def initialize(**kw)
      super(**DEFAULTS, **kw)
      freeze
    end

    def with(**kw) = self.class.new(**to_h.merge(kw))

    def secrets
      [newsmesh_api_key, admin_api_key, cron_secret, groq_api_key, database_url].select { |s| s && !s.empty? }
    end

    class << self
      def load_dotenv(path = nil)
        f = path || ENV["ENV_FILE"] || ".env"
        return unless File.file?(f)

        File.read(f, encoding: "UTF-8").each_line do |line|
          line = Util.py_strip(line)
          next if line.empty? || line.start_with?("#") || !line.include?("=")

          k, v = line.split("=", 2)
          k = Util.py_strip(Util.py_strip(k).delete_prefix("export "))
          v = Util.py_strip(v)
          if ["'", '"'].include?(v[0]) && v.count(v[0]) >= 2
            v = v[1...v.index(v[0], 1)]
          else
            v = Util.py_strip(v.split(" #", 2).first.to_s)
          end
          ENV[k] = v unless ENV.key?(k)
        end
      end

      def env(name, default = nil)
        v = ENV[name]
        v.nil? || v.strip.empty? ? default : v.strip
      end

      def int(name, default) = Integer(env(name, default.to_s))
      def float(name, default) = Float(env(name, default.to_s))

      def bool(name, default)
        v = env(name)
        v.nil? ? default : %w[1 true yes on].include?(v.downcase)
      end

      def list(name, default = "")
        (env(name, default) || "").split(",").map(&:strip).reject(&:empty?)
      end

      def from_env
        load_dotenv
        d = new
        sl = bool("SERVERLESS", !ENV["VERCEL"].to_s.empty?)
        new(
          app_env: env("APP_ENV", d.app_env), serverless: sl,
          database_url: env("DATABASE_URL") || env("POSTGRES_URL") || "", db_schema: env("DB_SCHEMA"),
          data_dir: env("DATA_DIR", sl ? "/tmp/aetheryon" : "./data"),
          admin_api_key: env("ADMIN_API_KEY"), user_agent: env("USER_AGENT", d.user_agent),
          cors_origins: list("CORS_ORIGINS"), cron_secret: env("CRON_SECRET"),
          source_timeout: float("SOURCE_TIMEOUT", sl ? "25" : d.source_timeout.to_s),
          stale_run_min: int("STALE_RUN_MIN", sl ? 6 : d.stale_run_min),
          scheduler_enabled: bool("SCHEDULER_ENABLED", !sl),
          collect_interval_min: int("COLLECT_INTERVAL_MIN", d.collect_interval_min),
          rss_min_interval_min: int("RSS_MIN_INTERVAL_MIN", d.rss_min_interval_min),
          steam_min_interval_min: int("STEAM_MIN_INTERVAL_MIN", d.steam_min_interval_min),
          steam_news_count: int("STEAM_NEWS_COUNT", d.steam_news_count),
          steam_max_games_per_run: int("STEAM_MAX_GAMES_PER_RUN", d.steam_max_games_per_run),
          newsmesh_api_key: env("NEWSMESH_API_KEY"), newsmesh_plan: env("NEWSMESH_PLAN", d.newsmesh_plan).downcase,
          newsmesh_base_url: env("NEWSMESH_BASE_URL", d.newsmesh_base_url),
          newsmesh_endpoint: env("NEWSMESH_ENDPOINT", d.newsmesh_endpoint),
          newsmesh_query_param: env("NEWSMESH_QUERY_PARAM", d.newsmesh_query_param),
          newsmesh_limit_param: env("NEWSMESH_LIMIT_PARAM", d.newsmesh_limit_param),
          newsmesh_auth_mode: env("NEWSMESH_AUTH_MODE", d.newsmesh_auth_mode).downcase,
          newsmesh_auth_name: env("NEWSMESH_AUTH_NAME", d.newsmesh_auth_name),
          newsmesh_queries: list("NEWSMESH_QUERIES", d.newsmesh_queries.join(",")),
          newsmesh_per_request: [10, int("NEWSMESH_PER_REQUEST", d.newsmesh_per_request)].min,
          newsmesh_daily_limit: int("NEWSMESH_DAILY_LIMIT", d.newsmesh_daily_limit),
          newsmesh_quota_reserve: int("NEWSMESH_QUOTA_RESERVE", d.newsmesh_quota_reserve),
          newsmesh_min_interval_min: int("NEWSMESH_MIN_INTERVAL_MIN", d.newsmesh_min_interval_min),
          groq_api_key: env("GROQ_API_KEY"), groq_base_url: env("GROQ_BASE_URL", d.groq_base_url),
          groq_model: env("GROQ_MODEL", d.groq_model), groq_temperature: float("GROQ_TEMPERATURE", d.groq_temperature),
          groq_max_tokens: int("GROQ_MAX_TOKENS", d.groq_max_tokens), groq_timeout: float("GROQ_TIMEOUT", d.groq_timeout),
          groq_concurrency: int("GROQ_CONCURRENCY", d.groq_concurrency), groq_max_rpm: int("GROQ_MAX_RPM", d.groq_max_rpm),
          groq_max_retries: int("GROQ_MAX_RETRIES", d.groq_max_retries),
          editorial_max_attempts: int("EDITORIAL_MAX_ATTEMPTS", d.editorial_max_attempts),
          editorial_batch_size: int("EDITORIAL_BATCH_SIZE", d.editorial_batch_size),
          editorial_worker_enabled: bool("EDITORIAL_WORKER_ENABLED", !sl),
          editorial_interval_s: int("EDITORIAL_INTERVAL_S", d.editorial_interval_s),
          editorial_intake_hours: int("EDITORIAL_INTAKE_HOURS", d.editorial_intake_hours),
          editorial_trending_limit: int("EDITORIAL_TRENDING_LIMIT", d.editorial_trending_limit),
          editorial_latest_limit: int("EDITORIAL_LATEST_LIMIT", d.editorial_latest_limit),
          editorial_lease_min: int("EDITORIAL_LEASE_MIN", d.editorial_lease_min)
        )
      end
    end
  end

  def self.redact(text, secrets)
    secrets.reduce(text) { |t, s| t.gsub(s, "***") }
  end
end
