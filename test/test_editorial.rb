# frozen_string_literal: true

require_relative "test_helper"

class TestEditorial < Minitest::Test
  include PgTest

  CH = { "Authorization" => "Bearer s3cret-cron-value" }.freeze
  ADM = { "X-API-Key" => "adm" }.freeze
  CATS = Classifier::CATEGORIES
  FEED = rss(
    rss_item("Nvidia unveils RTX 5090 priced at $1,999", "https://ign.com/a", guid: "a",
                                                                               desc: "Nvidia presented the RTX 5090 on Tuesday with a price of $1,999 and 32 GB of memory."),
    rss_item("Studio Alpha delays Game Beta to 2027", "https://ign.com/b", guid: "b",
                                                                           desc: "Studio Alpha said Game Beta will arrive in 2027 after a delay announced this week.")
  )

  # Simula los feeds y la API de Groq (compatible con OpenAI).
  class FakeWorld
    attr_accessor :mode, :calls, :statuses

    def initialize(mode = "ok")
      @mode = mode
      @calls = 0
      @statuses = []
      @lock = Mutex.new
    end

    def to_proc = method(:call).to_proc

    def call(req)
      if req.host.include?("api.groq.com")
        code = nil
        body = nil
        @lock.synchronize do
          @calls += 1
          raise "auth" unless req.headers["authorization"] == "Bearer gsk_TESTKEY"

          body = JSON.parse(req.content)
          raise "json mode" unless body["response_format"] == { "type" => "json_object" }

          code = @statuses.shift unless @statuses.empty?
        end
        return http_resp(code, headers: { "retry-after" => "0" }, json: { "error" => { "message" => "limite" } }) if code && code != 200

        user = JSON.parse(body["messages"][1]["content"])
        out = output(user, body["messages"])
        http_resp(200, json: { "model" => body["model"], "choices" => [{ "message" => { "content" => JSON.generate(out) } }],
                               "usage" => { "prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150 } })
      elsif req.host.include?("ign.com")
        http_resp(200, text: FEED)
      else
        http_resp(503)
      end
    end

    def output(user, messages)
      out = { "source_language" => "en", "translated" => true, "title" => "ES: #{user['title']}", "summary" => "Resumen: #{user['title']}",
              "body" => user["description"], "category" => "hardware", "categories" => %w[hardware technology bogus],
              "entities" => [{ "name" => "Nvidia", "type" => "organization" }, { "name" => "Inventada SA", "type" => "organization" }],
              "uncertainty" => [], "insufficient_info" => false }
      out["summary"] += " Costara $2,499." if mode == "invented" || (mode == "invented_once" && messages.size == 2)
      out
    end
  end

  class SpanishWorld < FakeWorld
    def output(user, messages) = super.merge("source_language" => "es", "translated" => false)
  end

  def make_app(world, key: "gsk_TESTKEY", **kw)
    s = settings.with(groq_api_key: key, groq_max_rpm: 0, groq_max_retries: 2, cron_secret: "s3cret-cron-value", admin_api_key: "adm",
                      editorial_worker_enabled: false, **kw)
    Application.new(s, client: fake_client(&world.to_proc))
  end

  def collect_and_process(c)
    assert c.get("/api/cron/collect", headers: CH, params: { source: "ign" }).json["ok"]
    c.get("/api/cron/process", headers: CH).json
  end

  def test_pipeline_end_to_end_and_distribution
    world = FakeWorld.new
    c = Client.new(make_app(world))
    st = collect_and_process(c)
    assert_equal 2, st["claimed"]
    assert_equal 2, st["completed"]
    assert_equal 2, st["intake"]["enqueued"]
    assert_equal 2, world.calls
    p = c.get("/api/news/processed").json
    assert_equal 2, p["total"]
    assert_equal 2, p["items"].size
    it = p["items"].find { |i| i["normalized"]["title"].include?("RTX") }
    assert_equal %w[id status url canonical_url published_at captured_at image_url author source game references original normalized editorial processing].sort, it.keys.sort
    ed = it["editorial"]
    assert ed["title"].start_with?("ES: ")
    assert_equal "es", ed["language"]
    assert_equal "en", ed["source_language"]
    assert ed["translated"]
    assert_equal ["Nvidia"], ed["entities"].map { |e| e["name"] } # "Inventada SA" no figura en el texto: descartada
    assert_equal %w[hardware technology], ed["categories"] # "bogus" fuera del catálogo: descartada
    assert_equal "Nvidia unveils RTX 5090 priced at $1,999", it["normalized"]["title"] # original intacto
    assert_equal "a", it["original"]["external_id"]
    assert_equal ["News"], it["original"]["categories"]
    pr = it["processing"]
    assert_equal Editorial::Prompts::PIPELINE_VERSION, pr["pipeline_version"]
    assert_equal({ "prompt" => 100, "completion" => 50 }, pr["tokens"])
    assert_equal 1, pr["attempts"]
    assert_equal settings.groq_model, pr["model"]
    assert_equal "ign", it["references"][0]["source"]
    g = ->(**k) { c.get("/api/news/processed", params: k).json["total"] }
    assert_equal [2, 2, 0], [g.call(category: "hardware"), g.call(category: "technology"), g.call(category: "esports")]
    assert_equal [2, 0, 2, 0], [g.call(language: "en"), g.call(language: "pt"), g.call(source: "ign"), g.call(source: "kotaku")]
    assert_equal [0, 0, 2], [g.call(date_from: "2099-01-01T00:00:00Z"), g.call(date_to: "2000-01-01T00:00:00Z"), g.call(date_from: "2000-01-01T00:00:00Z")]
    assert_equal 2, c.get("/api/news/processed", params: { page_size: 1 }).json["pages"]
    assert_equal 422, c.get("/api/news/processed", params: { category: "nope" }).status
    q = c.get("/api/news/queue").json
    assert_equal({ "pending" => 0, "processing" => 0, "completed" => 2, "failed" => 0 }, q["counts"])
    assert_equal 2, q["total"]
    assert_equal 2, q["usage_today"]["calls"]
    assert_equal 300, q["usage_today"]["total_tokens"]
    assert q["worker"]["enabled"]
    assert_equal 0, c.get("/api/news/queue", params: { status: "pending" }).json["total"]
    assert_equal 422, c.get("/api/news/queue", params: { status: "zzz" }).status
    assert_equal 2, c.get("/api/news/latest").json["total"]
    assert_equal 2, c.get("/api/news/trending").json.size
    assert_equal it["normalized"]["title"], c.get("/api/news/#{it['id']}").json["title"]
  end

  def test_no_unnecessary_reprocessing
    world = FakeWorld.new
    c = Client.new(make_app(world))
    collect_and_process(c)
    assert_equal 0, c.get("/api/cron/process", headers: CH).json["claimed"]
    assert_equal 2, world.calls
    db.conn { |k| k.execute("UPDATE articles SET description=description||' Updated.' WHERE title LIKE 'Nvidia%'") }
    st = c.get("/api/cron/process", headers: CH).json
    assert_equal 1, st["claimed"]
    assert_equal 1, st["intake"]["requeued"]
    assert_equal 3, world.calls
    db.conn { |k| k.execute("UPDATE news_queue SET pipeline_version='editorial-old'") }
    assert_equal 2, c.get("/api/cron/process", headers: CH).json["completed"]
    assert_equal 5, world.calls
    assert_equal Editorial::Prompts::PIPELINE_VERSION, c.get("/api/news/processed").json["items"][0]["processing"]["pipeline_version"]
  end

  def test_invented_numbers_rejected_then_corrected_with_feedback
    world = FakeWorld.new("invented_once")
    c = Client.new(make_app(world))
    st = collect_and_process(c)
    assert_equal 2, st["completed"]
    assert_equal 4, world.calls
    use = db.conn { |k| k.execute("SELECT status, COUNT(*) n FROM llm_usage GROUP BY status").to_h { |r| [r["status"], r["n"]] } }
    assert_equal({ "ok" => 2, "rejected" => 2 }, use)
  end

  def test_persistent_invention_ends_failed_and_is_never_distributed
    world = FakeWorld.new("invented")
    c = Client.new(make_app(world))
    collect_and_process(c)
    2.times do # intentos 2 y 3: se salta el backoff
      db.conn { |k| k.execute("UPDATE news_queue SET next_attempt_at=NULL") }
      c.get("/api/cron/process", headers: CH)
    end
    q = c.get("/api/news/queue", params: { status: "failed" }).json
    assert_equal 2, q["total"]
    assert_equal 3, q["items"][0]["attempts"]
    assert_includes q["items"][0]["last_error"], "Validación editorial"
    assert_equal 0, c.get("/api/news/processed").json["total"]
    assert_equal 12, world.calls
    assert_equal 0, c.get("/api/cron/process", headers: CH).json["claimed"] # failed no se reintenta solo
  end

  def test_retries_on_429_and_usage_logged
    world = FakeWorld.new
    world.statuses = [429, 429]
    c = Client.new(make_app(world))
    st = collect_and_process(c)
    assert_equal 2, st["completed"]
    assert_equal 4, world.calls
    assert_equal 2, db.conn { |k| k.execute("SELECT SUM(retries) FROM llm_usage").fetchone[0] }
  end

  def test_provider_errors_back_off_then_fail
    world = FakeWorld.new
    world.statuses = [500] * 100
    c = Client.new(make_app(world))
    st = collect_and_process(c)
    assert_equal 2, st["retry"]
    assert_equal 0, st["completed"]
    q = c.get("/api/news/queue", params: { status: "pending" }).json
    assert_equal 2, q["total"]
    assert q["items"][0]["next_attempt_at"]
    assert_includes q["items"][0]["last_error"], "HTTP 500"
    assert_equal 0, c.get("/api/cron/process", headers: CH).json["claimed"] # en backoff
    world2 = FakeWorld.new
    world2.statuses = [401] * 100 # no reintentable: falla de inmediato
    c2 = Client.new(make_app(world2))
    db.conn { |k| k.execute("UPDATE news_queue SET next_attempt_at=NULL") }
    assert_equal 2, c2.get("/api/cron/process", headers: CH).json["failed"]
  end

  def test_individual_process_endpoint
    world = FakeWorld.new
    c = Client.new(make_app(world))
    c.get("/api/cron/collect", headers: CH, params: { source: "ign" })
    aid = c.get("/api/news").json["items"][0]["id"]
    assert_equal 401, c.post("/api/news/#{aid}/process").status
    assert_equal 404, c.post("/api/news/art_nope/process", headers: ADM).status
    r = c.post("/api/news/#{aid}/process", headers: ADM)
    assert_equal 202, r.status
    assert_equal "pending", r.json["status"]
    assert_equal "manual", r.json["enqueued_by"]
    assert_equal 100, r.json["priority"]
    assert_equal 0, c.get("/api/news/processed").json["total"] # pendiente: no se distribuye
    r = c.post("/api/news/#{aid}/process", params: { wait: true }, headers: ADM)
    assert_equal 200, r.status
    assert_equal "completed", r.json["status"]
    assert_equal 1, world.calls
    assert_equal 1, c.get("/api/news/processed").json["total"]
    assert_equal "completed", c.post("/api/news/#{aid}/process", params: { wait: true }, headers: ADM).json["status"]
    assert_equal 1, world.calls
    r = c.post("/api/news/#{aid}/process", params: { wait: true, force: true }, headers: ADM)
    assert_equal 200, r.status
    assert_equal 2, world.calls
  end

  def test_pipeline_disabled_without_groq_key
    c = Client.new(make_app(FakeWorld.new, key: nil))
    assert_equal "groq_not_configured", c.get("/api/cron/process", headers: CH).json["skipped"]
    assert_equal 401, c.get("/api/cron/process").status
    c.get("/api/cron/collect", headers: CH, params: { source: "ign" })
    aid = c.get("/api/news").json["items"][0]["id"]
    assert_equal 503, c.post("/api/news/#{aid}/process", headers: ADM).status
    assert_equal 0, c.get("/api/news/processed").json["total"]
    assert_equal false, c.get("/api/news/queue").json["worker"]["enabled"]
  end

  TITLES = ["Alpha studio reveals dragon adventure", "Beta console price drop announced", "Gamma esports finals draw record crowd",
            "Delta indie hit surpasses million sales", "Epsilon patch fixes crash on launch", "Zeta handheld gets battery upgrade"].freeze

  def seed(n = 6)
    db.conn { |k| k.execute("INSERT INTO sources(key, name, kind) VALUES('s','S','rss')") }
    Store.ingest(db, TITLES.first(n).each_with_index.map do |t, i|
      Normalizer.build_item(source_key: "s", title: t, url: "https://s.test/#{i}", description: "Texto de prueba suficientemente largo para la fuente.")
    end)
    Repository.list_articles(db, Repository::Filters.new, 1, 50)["items"]
  end

  def test_claims_are_exclusive_and_leases_recover
    items = seed
    wq = Editorial::WorkQueue
    assert_equal 6, wq.enqueue(db, items, "latest")["enqueued"]
    assert_equal 6, wq.enqueue(db, items, "latest")["skipped"]
    got = Array.new(3) { Thread.new { wq.claim_batch(db, settings, 6).map { |x| x["article_id"] } } }.map(&:value)
    flat = got.flatten
    assert_equal 6, flat.size
    assert_equal 6, flat.uniq.size # ningún ítem reclamado dos veces
    db.conn { |k| k.execute("UPDATE news_queue SET lease_until='2000-01-01T00:00:00+00:00'") }
    again = wq.claim_batch(db, settings, 6)
    assert_equal 6, again.size
    assert_equal [2], again.map { |a| a["attempts"] }.uniq # lease vencido: vuelve a la cola
    db.conn { |k| k.execute("UPDATE news_queue SET lease_until='2000-01-01T00:00:00+00:00', attempts=3") }
    assert_equal [], wq.claim_batch(db, settings, 6)
    assert_equal 6, wq.queue_page(db, settings, nil, 1, 20)["counts"]["failed"]
  end

  def test_priority_order
    items = seed(3)
    wq = Editorial::WorkQueue
    wq.enqueue(db, items, "latest", 0)
    wq.enqueue(db, [items[2]], "manual", 100)
    assert_equal items[2]["id"], wq.claim_batch(db, settings, 1)[0]["article_id"]
  end

  def test_off_topic_category_entity_taxonomy_and_prompt_rules
    sports = { "source_language" => "en", "translated" => true, "title" => "Nebraska vence a Ohio State en fútbol americano universitario",
               "summary" => "El encuentro universitario terminó tras un partido disputado.",
               "body" => "Nebraska derrotó a Ohio State en un encuentro de fútbol americano universitario.",
               "category" => "off_topic", "categories" => ["off_topic"],
               "entities" => [{ "name" => "Nebraska", "type" => "organization" }, { "name" => "Ohio State", "type" => "organization" }],
               "uncertainty" => [], "insufficient_info" => false }
    ps = Editorial::Validate.parse_output(JSON.generate(sports), "Nebraska defeats Ohio State in college football",
                                          "The college football game ended after a close match between the two teams.", CATS, "gaming")
    assert_equal "off_topic", ps.category
    assert_equal ["off_topic"], ps.categories
    game = { "source_language" => "en", "translated" => true, "title" => "Piranha Plant aparece en Mario Kart World",
             "summary" => "El personaje Piranha Plant aparece en el videojuego Mario Kart World.", "body" => "Piranha Plant forma parte de Mario Kart World.",
             "category" => "gaming", "categories" => ["gaming"],
             "entities" => [{ "name" => "Piranha Plant", "type" => "character" }, { "name" => "Mario Kart World", "type" => "game" }],
             "uncertainty" => [], "insufficient_info" => false }
    pg = Editorial::Validate.parse_output(JSON.generate(game), "Piranha Plant appears in Mario Kart World",
                                          "The character Piranha Plant is included in the video game Mario Kart World.", CATS, "gaming")
    assert_equal [{ "name" => "Piranha Plant", "type" => "character" }, { "name" => "Mario Kart World", "type" => "game" }], pg.entities
    sp = Editorial::Prompts.build_messages("title", "description", "source", CATS)[0]["content"]
    assert_includes sp, '"off_topic"'
    assert_includes sp, "No traduzcas literalmente modismos"
    assert_includes sp, "fictional_location"
  end

  def test_validate_numbers_entities_and_flags
    v = Editorial::Validate
    src_t = "Nvidia launches RTX 5090 at $1,999"
    src_d = "The card ships in March 2027 with 32 GB of memory and a 575 W limit."
    ok = { "source_language" => "en", "translated" => true, "title" => "Nvidia lanza la RTX 5090 a 1.999 dólares", "summary" => "Resumen.",
           "body" => "Llega en marzo de 2027 con 32 GB y 575 W.", "category" => "zzz", "categories" => ["hardware"],
           "entities" => [{ "name" => "NVIDIA", "type" => "organization" }, { "name" => "AMD", "type" => "organization" }, { "name" => "nvidia", "type" => "x" }],
           "uncertainty" => [], "insufficient_info" => false }
    ed = v.parse_output("```json\n#{JSON.generate(ok)}\n```", src_t, src_d, CATS, "gaming")
    assert_equal Set["1999"], v.numbers("$1,999")
    assert_equal v.numbers("$1,999"), v.numbers("1.999")
    assert_equal "gaming", ed.category
    assert_equal %w[gaming hardware], ed.categories # categoría inválida → fallback
    assert_equal ["NVIDIA"], ed.entities.map { |e| e["name"] }
    assert_equal ["AMD"], ed.dropped_entities
    refute ed.insufficient_info
    tiny = "March 2027, 32 GB, 575 W."
    short = v.parse_output(JSON.generate(ok), src_t, tiny, CATS, "gaming") # extracto insuficiente
    assert short.insufficient_info
    assert(short.uncertainty.any? { |u| u.include?("extracto") })
    assert_operator v::MIN_SOURCE_CHARS, :>, tiny.length
    [ok.merge("summary" => "Cuesta 2.499 dólares."), ok.merge("title" => ""), ok.merge("body" => "x" * 2000)].each do |bad|
      assert_raises(v::ValidationError) { v.parse_output(JSON.generate(bad), src_t, src_d, CATS, "gaming") }
    end
    ["no es json", "[1,2]"].each { |raw| assert_raises(v::ValidationError) { v.parse_output(raw, src_t, src_d, CATS, "gaming") } }
  end

  def test_spanish_endpoint_flat_shape_filters_and_pending
    world = FakeWorld.new
    c = Client.new(make_app(world, editorial_batch_size: 1))
    c.get("/api/cron/collect", headers: CH, params: { source: "ign" })
    empty = c.get("/api/news/es").json
    assert_equal [], empty["items"]
    assert_equal 0, empty["total"]
    assert_equal 0, empty["pending"] # nada encolado todavía
    c.get("/api/cron/process", headers: CH) # lote de 1: queda 1 pendiente
    p = c.get("/api/news/es").json
    assert_equal [1, 1], [p["total"], p["pending"]]
    c.get("/api/cron/process", headers: CH)
    p = c.get("/api/news/es").json
    assert_equal [2, 0, 1], [p["total"], p["pending"], p["pages"]]
    it = p["items"].find { |i| i["original_title"].include?("RTX") }
    assert_equal %w[id language title summary body category categories entities uncertainty insufficient_info translated source_language
                    original_title url source published_at image_url author game references generated_at model].sort, it.keys.sort
    assert_equal "es", it["language"]
    assert it["title"].start_with?("ES: ")
    assert it["translated"]
    assert_equal "en", it["source_language"]
    assert_equal "Nvidia unveils RTX 5090 priced at $1,999", it["original_title"]
    assert_equal "ign", it["source"]["key"]
    g = ->(**k) { c.get("/api/news/es", params: k).json["total"] }
    assert_equal [2, 0, 2, 0], [g.call(translated: true), g.call(translated: false), g.call(category: "hardware"), g.call(source: "kotaku")]
    assert_equal 2, c.get("/api/news/es", params: { page_size: 1 }).json["pages"]
    assert_equal 422, c.get("/api/news/es", params: { category: "nope" }).status
    assert_equal 200, c.get("/api/news/#{it['id']}").status # /{id} sigue funcionando
  end

  def test_spanish_endpoint_translated_filter_with_spanish_sources
    c = Client.new(make_app(SpanishWorld.new))
    collect_and_process(c)
    g = ->(**k) { c.get("/api/news/es", params: k).json["total"] }
    assert_equal [2, 2, 0], [g.call, g.call(translated: false), g.call(translated: true)]
  end
end
