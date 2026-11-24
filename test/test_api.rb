# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/terra_gazette_client"

class TestApi < Minitest::Test
  include PgTest

  ADM = { "X-API-Key" => "adm" }.freeze

  FEEDS = lambda do |req|
    h = req.host
    if h.include?("api.steampowered.com") && req.path.include?("GetNewsForApp")
      http_resp(200, json: { "appnews" => { "newsitems" => [] } })
    elsif h.include?("api.steampowered.com") # GetAppList
      http_resp(200, json: { "applist" => { "apps" => [{ "appid" => 620, "name" => "Portal 2" }, { "appid" => 730, "name" => "Counter-Strike 2" }] } })
    elsif h.include?("ign.com")
      http_resp(200, text: rss(rss_item("Nvidia unveils new RTX GPU for gamers", "https://ign.com/a", img: "https://i/a.jpg"),
                               rss_item("Studio announces launch date for big RPG", "https://ign.com/b")))
    elsif h.include?("pcgamer.com")
      http_resp(200, text: rss(rss_item("Nvidia unveils new RTX GPU for gamers!", "https://pcgamer.com/x")))
    else
      http_resp(503) # el resto de feeds caídos
    end
  end

  def make_app(handler = FEEDS, **kw)
    Application.new(settings.with(admin_api_key: "adm", **kw), client: fake_client(&handler))
  end

  def wait_done(c)
    100.times do
      st = c.get("/api/sync/status").json
      return st unless st["running"]

      sleep 0.05
    end
    flunk "la recolección no terminó"
  end

  def test_end_to_end
    c = Client.new(make_app)
    assert_equal({ "status" => "ok" }, c.get("/health").json)
    assert_equal 9, c.get("/api/sources").json.size
    assert_equal 401, c.post("/api/collect").status
    r = c.post("/api/collect", headers: ADM, json: { "sources" => %w[ign pcgamer kotaku] })
    assert_equal 202, r.status
    assert_includes [409, 202], c.post("/api/collect", headers: ADM).status
    st = wait_done(c)
    assert_equal "partial", st["last_run"]["status"]
    assert_equal 2, st["total_articles"]
    news = c.get("/api/news").json
    assert_equal 2, news["total"]
    nv = news["items"].find { |a| a["title"].include?("Nvidia") }
    assert_equal %w[ign pcgamer], nv["references"].map { |x| x["source"] }.sort
    assert_includes nv["categories"], "hardware"
    assert_equal ["News"], nv["original"]["categories"]
    assert nv["classification"]["version"]
    assert_equal "https://i/a.jpg", nv["image_url"]
    assert_nil nv["score"]
    assert_equal 1, c.get("/api/news", params: { source: "pcgamer" }).json["total"]
    assert_equal 1, c.get("/api/news", params: { category: "releases" }).json["total"]
    assert_equal 422, c.get("/api/news", params: { category: "nope" }).status
    assert_equal 2, c.get("/api/news", params: { page_size: 1 }).json["pages"]
    assert_equal 1, c.get("/api/news/search", params: { q: "rtx" }).json["total"]
    assert_equal 0, c.get("/api/news/search", params: { q: "100%" }).json["total"]
    assert_equal 2, c.get("/api/news/latest").json["total"]
    tr = c.get("/api/news/trending").json
    assert_equal nv["id"], tr[0]["id"]
    assert_operator tr[0]["score"], :>, tr[1]["score"]
    assert_equal nv["id"], c.get("/api/news/#{nv['id']}").json["id"]
    assert_equal 404, c.get("/api/news/zzz").status
    assert_equal 1, c.get("/api/categories").json.to_h { |x| [x["name"], x["count"]] }["hardware"]
    by = c.get("/api/sources").json.to_h { |s| [s["key"], s] }
    assert_equal "ok", by["ign"]["status"]
    assert_equal "error", by["kotaku"]["status"]
    assert_equal 25, by["newsmesh"]["quota"]["daily_limit"]
    assert_equal false, c.post("/api/sources/ign/pause", headers: ADM).json["enabled"]
    assert_equal true, c.post("/api/sources/ign/test", headers: ADM).json["ok"]
    t = c.post("/api/sources/kotaku/test", headers: ADM).json
    assert_equal false, t["ok"]
    assert_includes t["error"], "503"
    assert_equal 404, c.post("/api/sources/nada/test", headers: ADM).status
    refute_empty c.get("/api/sync/runs").json[0]["sources"]
    assert_equal 200, c.get("/panel").status
    assert_equal 200, c.get("/docs").status
    recs = TerraGazetteClient.new(http: c).candidates(hours: 72)
    refute_empty recs
    assert_equal "pending_editorial_review", recs[0]["status"]
    assert recs[0]["attribution"][0]["url"].start_with?("https://")
  end

  def test_game_catalog
    c = Client.new(make_app)
    g = c.post("/api/games", headers: ADM, json: { "name" => "Whatever", "url" => "https://store.steampowered.com/app/1245620/ELDEN_RING/", "franchise" => "Elden Ring" })
    assert_equal 201, g.status
    assert_equal 1_245_620, g.json["appid"]
    assert_equal "url", g.json["resolution"]
    assert_equal "Elden Ring", g.json["franchise"]
    assert_equal 1, c.get("/api/games", params: { franchise: "elden ring" }).json.size
    assert_equal [{ "name" => "Elden Ring", "count" => 1 }], c.get("/api/games/franchises").json
    g = c.post("/api/games", headers: ADM, json: { "name" => "Portal 2" }).json
    assert_equal 620, g["appid"]
    assert_equal "catalog", g["resolution"]
    u = c.post("/api/games", headers: ADM, json: { "name" => "Juego Rarísimo" }).json
    assert_equal "unresolved", u["status"]
    assert_nil u["appid"]
    assert_equal false, u["resolved"]
    assert_equal 409, c.post("/api/games", headers: ADM, json: { "name" => "dup", "appid" => 620 }).status
    p = c.patch("/api/games/#{u['id']}", headers: ADM, json: { "appid" => 4242, "franchise" => "Test Saga" }).json
    assert_equal "active", p["status"]
    assert_equal "manual", p["resolution"]
    assert_equal "Test Saga", p["franchise"]
    assert_equal 1, c.get("/api/games", params: { franchise: "Test Saga" }).json.size
    assert_equal [730], c.get("/api/games/steam-search", params: { q: "counter" }).json.map { |x| x["appid"] }
    assert_equal 3, c.get("/api/games", params: { status: "active" }).json.size
    assert_equal 204, c.delete("/api/games/#{u['id']}", headers: ADM).status
    # la recolección de Steam usa el catálogo
    c.post("/api/collect", headers: ADM, json: { "sources" => ["steam"] })
    run = wait_done(c)["last_run"]
    assert_equal "ok", run["sources"][0]["status"]
  end

  def test_validation_errors_follow_fastapi_shape
    c = Client.new(make_app)
    r = c.get("/api/news", params: { page: 0, page_size: 101 })
    assert_equal 422, r.status
    d = r.json["detail"]
    assert_equal %w[greater_than_equal less_than_equal], d.map { |e| e["type"] }
    assert_equal %w[query page], d[0]["loc"]
    assert_equal 422, c.get("/api/games/abc").status
    assert_equal 422, c.post("/api/games", headers: ADM, json: { "name" => "" }).status
    assert_equal 404, c.get("/api/nope").status
    assert_equal({ "detail" => "Not Found" }, c.get("/api/nope").json)
    assert_equal 405, c.post("/api/news").status
  end

  def test_catalog_unavailable_falls_back_to_manual
    c = Client.new(make_app(->(_r) { http_resp(500) }))
    g = c.post("/api/games", headers: ADM, json: { "name" => "Portal 2" }).json
    assert_equal "unresolved", g["status"] # no rompe: queda para carga manual
    assert_equal 503, c.get("/api/games/steam-search", params: { q: "portal" }).status
  end

  def test_production_requires_admin_key
    app = Application.new(settings.with(app_env: "production", admin_api_key: nil), client: fake_client(&FEEDS))
    assert_equal 503, Client.new(app).post("/api/collect").status
  end

  def test_openapi_documents_every_real_route
    spec = make_app.openapi
    assert_includes spec["paths"], "/api/news/es"
    refute_includes spec["paths"]["/api/cron/process"], "post"
    ids = spec["paths"].values.flat_map(&:values).map { |o| o["operationId"] }
    assert_equal ids.uniq, ids
    Base.routes["GET"].each do |pattern, *_|
      # cada ruta GET de la app existe en la tabla de rutas (salvo docs/utilidades)
      next unless pattern.to_s.include?("api")
    end
    paths = OpenAPI.route_table.map { |m, p, _| "#{m} #{p}" }
    %w[GET\ /api/news GET\ /api/games/franchises POST\ /api/collect GET\ /api/sync/runs/{run_id}].each { |k| assert_includes paths, k }
  end
end
