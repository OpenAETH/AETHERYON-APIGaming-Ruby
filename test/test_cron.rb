# frozen_string_literal: true

require_relative "test_helper"

class TestCron < Minitest::Test
  include PgTest

  H = { "Authorization" => "Bearer s3cret-cron-value" }.freeze

  FEEDS = lambda do |req|
    if req.host.include?("ign.com")
      http_resp(200, text: rss(rss_item("Nvidia unveils new RTX GPU for gamers", "https://ign.com/a")))
    else
      http_resp(503)
    end
  end

  def make_app(**kw)
    Application.new(settings.with(cron_secret: "s3cret-cron-value", admin_api_key: "adm", **kw), client: fake_client(&FEEDS))
  end

  def test_cron_auth
    c = Client.new(make_app)
    assert_equal 401, c.get("/api/cron/collect").status
    assert_equal 401, c.get("/api/cron/collect", headers: { "Authorization" => "Bearer nope" }).status
    assert_equal 401, c.get("/api/cron/collect", headers: { "X-API-Key" => "adm" }).status # la admin key no sirve acá
    c2 = Client.new(Application.new(settings, client: fake_client(&FEEDS))) # sin CRON_SECRET: deshabilitado
    assert_equal 503, c2.get("/api/cron/collect", headers: H).status
  end

  def test_cron_collect_runs_inline_and_respects_intervals
    c = Client.new(make_app)
    r = c.get("/api/cron/collect", headers: H, params: { source: "ign" })
    assert_equal 200, r.status
    assert r.json["ok"]
    assert_equal "success", r.json["run"]["status"]
    assert_equal 1, r.json["run"]["sources"][0]["new"]
    assert_equal 1, c.get("/api/news").json["total"] # ya persistido al responder
    r2 = c.post("/api/cron/collect", headers: H, params: { source: "ign" }) # sin force: la fuente no está vencida
    assert_equal "skipped", r2.json["run"]["sources"][0]["status"]
    assert_equal 422, c.get("/api/cron/collect", headers: H, params: { source: "zzz" }).status
  end

  def test_cron_all_sources_failing_returns_502
    r = Client.new(make_app).get("/api/cron/collect", headers: H, params: { source: "kotaku" })
    assert_equal 502, r.status
    assert_equal false, r.json["ok"]
  end

  def test_manual_collect_is_inline_in_serverless
    db # serverless no migra al arrancar: `db` ya migró
    r = Client.new(make_app(serverless: true)).post("/api/collect", headers: { "X-API-Key" => "adm" }, json: { "sources" => ["ign"] })
    assert_equal 200, r.status
    assert_equal "success", r.json["status"]
    assert_equal r.json["run"]["id"], r.json["run_id"]
  end

  def test_only_one_run_across_instances
    adapters = [RssAdapter.new("a", "A", "https://a.test/f")]
    Registry.sync_sources_table(db, adapters)
    handler = ->(_r) { http_resp(200, text: rss(rss_item("Titulo con varias palabras", "https://a.test/1"))) }
    c1 = Collector.new(db, settings, adapters, -> { fake_client(&handler) })
    c2 = Collector.new(db, settings, adapters, -> { fake_client(&handler) })
    _id, th = c1.start_with_thread("manual", nil, true)
    assert_raises(AlreadyRunning) { c2.start } # otra instancia (otro proceso en producción), misma base
    th.join
    assert_equal "success", c2.run(force: true)["status"] # liberada: ahora sí corre
  end

  def test_stale_runs_are_reclaimed
    db.conn { |c| c.execute("INSERT INTO sync_runs(trigger, started_at, status) VALUES('manual','2020-01-01T00:00:00+00:00','running')") }
    col = Collector.new(db, settings, [], -> {})
    assert_operator col.start, :>, 0
    col.thread.join
    assert_equal "interrupted", db.conn { |c| c.execute("SELECT status FROM sync_runs ORDER BY id").fetchone[0] }
  end
end
