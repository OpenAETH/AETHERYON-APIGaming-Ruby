# frozen_string_literal: true

require_relative "test_helper"

class TestPipeline < Minitest::Test
  include PgTest

  def item(src, title, url, game: nil, **kw)
    Normalizer.build_item(source_key: src, title: title, url: url, game_appid: game, published: "2026-11-05T10:00:00Z", **kw)
  end

  def collector(handler, adapters)
    Registry.sync_sources_table(db, adapters)
    client = fake_client(&handler)
    Collector.new(db, settings, adapters, -> { client })
  end

  def test_dedup_rules
    Registry.sync_sources_table(db, [RssAdapter.new("ign", "IGN", "u"), RssAdapter.new("kotaku", "Kotaku", "u"), SteamAdapter.new])
    assert_equal 1, Store.ingest(db, [item("ign", "Big Studio Announces Brand New Game Today", "https://ign.com/a?utm_source=x")]).new
    # misma URL canónica desde otra fuente -> referencia
    assert_equal 1, Store.ingest(db, [item("kotaku", "Otro titulo", "https://www.ign.com/a/")]).duplicates
    # mismo título exacto, URL distinta -> referencia
    assert_equal 1, Store.ingest(db, [item("kotaku", "Big studio announces brand-new game today!", "https://kotaku.com/z")]).duplicates
    # re-captura -> seen
    assert_equal 1, Store.ingest(db, [item("ign", "Big Studio Announces Brand New Game Today", "https://ign.com/a")]).seen
    assert_equal 1, count
    assert_equal 3, count("article_refs")
    # títulos parecidos pero distintos NO se fusionan
    assert_equal 1, Store.ingest(db, [item("ign", "Big Studio Announces Brand New Game Tomorrow", "https://ign.com/b")]).new
    # títulos cortos iguales no se fusionan; mismo título en distinto juego tampoco
    assert_equal 2, Store.ingest(db, [item("ign", "Patch notes", "https://ign.com/p1"), item("kotaku", "Patch notes", "https://kotaku.com/p2")]).new
    assert_equal 2, Store.ingest(db, [item("steam", "Update 1.2 is now live", "https://s/1", game: 10),
                                      item("steam", "Update 1.2 is now live", "https://s/2", game: 20)]).new
  end

  def test_fault_isolation_cache_and_run_log
    calls = Hash.new(0)
    handler = lambda do |req|
      if req.host.include?("ign.test")
        calls["ign"] += 1
        http_resp(200, text: rss(rss_item("IGN story with many words here", "https://ign.test/1", img: "https://i/1.jpg")), headers: { "etag" => "abc" })
      elsif req.host.include?("bad.test")
        http_resp(500)
      else
        http_resp(200, text: rss(rss_item("Kotaku other story with words", "https://kotaku.test/1")))
      end
    end
    adapters = [RssAdapter.new("ign", "IGN", "https://ign.test/feed"), RssAdapter.new("bad", "Bad", "https://bad.test/feed"),
                RssAdapter.new("kotaku", "Kotaku", "https://kotaku.test/feed")]
    col = collector(handler, adapters)
    r = col.run
    st = r["sources"].to_h { |s| [s["source_key"], s] }
    assert_equal "partial", r["status"]
    assert_equal "ok", st["ign"]["status"]
    assert_equal "ok", st["kotaku"]["status"]
    assert_equal "error", st["bad"]["status"]
    assert_includes st["bad"]["error"], "500"
    assert_equal 2, count
    assert_equal ["error", 1], db.conn { |c| c.execute("SELECT status, consecutive_failures FROM sources WHERE key='bad'").fetchone.values }
    # segunda corrida programada (no forzada): dentro del intervalo -> se omiten, sin tocar la red
    col.run(trigger: "scheduled", force: false)
    assert_equal 1, calls["ign"]
  end

  class Crash < RssAdapter
    def fetch(_ctx) = raise("boom")
  end

  def test_adapter_crash_does_not_block_others
    ok = RssAdapter.new("ok", "OK", "https://ok.test/feed")
    col = collector(->(_r) { http_resp(200, text: rss(rss_item("Titulo con varias palabras", "https://ok.test/1"))) }, [Crash.new("crash", "Crash", "x"), ok])
    r = col.run
    assert_equal({ "crash" => "error", "ok" => "ok" }, r["sources"].to_h { |s| [s["source_key"], s["status"]] })
  end

  def test_concurrent_runs_blocked
    col = collector(->(_r) { http_resp(200, text: rss(rss_item("Titulo con varias palabras", "https://a.test/1"))) }, [RssAdapter.new("a", "A", "https://a.test/f")])
    _id, th = col.start_with_thread("manual", nil, true)
    assert_raises(AlreadyRunning) { col.start }
    th.join
  end

  STEAM = lambda do |req|
    appid = req.params["appid"]
    if appid == "999"
      http_resp(403)
    else
      http_resp(200, json: { "appnews" => { "appid" => appid.to_i, "newsitems" => [
        { "gid" => "g1", "title" => "Patch 1.5 released today", "url" => "https://store.steampowered.com/news/1", "author" => "dev",
          "contents" => "[img]{STEAM_CLAN_IMAGE}/1/a.png[/img] [b]Fixes[/b] many bugs", "feedlabel" => "Community Announcements",
          "date" => 1_793_872_800, "feedname" => "steam_community_announcements", "feed_type" => 1, "appid" => appid.to_i, "tags" => ["patchnotes"] }
      ] } })
    end
  end

  def test_steam_adapter_per_game_isolation
    db.conn do |c|
      [["Good", 10], ["Forbidden", 999]].each do |n, a|
        c.execute("INSERT INTO games(name, appid, platform, status, created_at, updated_at) VALUES(?,?,?,?,?,?)", [n, a, "pc", "active", "t", "t"])
      end
      c.execute("INSERT INTO games(name, status, created_at, updated_at) VALUES('NoId','unresolved','t','t')")
    end
    s = collector(STEAM, [SteamAdapter.new]).run["sources"][0]
    assert_equal "degraded", s["status"]
    assert_equal 1, s["new"]
    assert(s["warnings"].any? { |w| w.include?("Forbidden") })
    db.conn do |c|
      a = c.execute("SELECT * FROM articles").fetchone
      assert_equal 10, a["game_appid"]
      assert a["image_url"].end_with?("/1/a.png")
      refute_includes a["description"], "["
      assert_includes JSON.parse(c.execute("SELECT categories FROM classifications").fetchone[0]), "updates"
    end
  end

  def test_newsmesh_license_and_missing_key
    a = NewsMeshAdapter.new
    assert_includes a.availability(settings.with(newsmesh_api_key: nil)), "NEWSMESH_API_KEY"
    assert_includes a.availability(settings.with(app_env: "production")), "comercial"
    assert_nil a.availability(settings.with(app_env: "production", newsmesh_plan: "commercial"))
  end

  def test_newsmesh_quota_cache_and_no_secret_leak
    s = settings.with(newsmesh_daily_limit: 3, newsmesh_quota_reserve: 1, newsmesh_queries: %w[a b])
    seen = []
    handler = lambda do |req|
      seen << req.url
      http_resp(200, json: { "data" => [{ "title" => "NewsMesh story title here", "link" => "https://nm.test/#{seen.size}",
                                          "description" => "d", "published_date" => "2026-11-05T10:00:00Z", "category" => "gaming" }] })
    end
    adapters = [NewsMeshAdapter.new]
    Registry.sync_sources_table(db, adapters)
    client = fake_client(&handler)
    col = Collector.new(db, s, adapters, -> { client })
    r1 = col.run
    assert_equal 2, r1["sources"][0]["requests"]
    assert_equal 2, col.quota.used("newsmesh")
    # forzar de nuevo: solo queda 0 de cuota útil (3 - reserva 1 = 2) -> bloqueado sin llamar a la red
    n = seen.size
    r2 = col.run
    assert_equal "quota_exhausted", r2["sources"][0]["status"]
    assert_equal n, seen.size
    # sin forzar y con caché vigente: ni red ni cuota
    col.run(force: false)
    assert_equal n, seen.size
    keys = db.conn { |c| c.execute("SELECT key FROM http_cache").map { |r| r["key"] } }
    assert(keys.none? { |k| k.include?("SECRETKEY123") })
  end
end
