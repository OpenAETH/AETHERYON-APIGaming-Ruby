# frozen_string_literal: true

require_relative "test_helper"

class TestUnits < Minitest::Test
  def test_canonical_url_strips_tracking_and_normalizes
    a = Normalizer.canonicalize_url("http://www.IGN.com/articles/foo/?utm_source=x&b=2&a=1#frag")
    b = Normalizer.canonicalize_url("https://ign.com/articles/foo?a=1&b=2")
    assert_equal "https://ign.com/articles/foo?a=1&b=2", a
    assert_equal a, b
    assert_nil Normalizer.canonicalize_url("javascript:alert(1)")
    assert_nil Normalizer.canonicalize_url("")
  end

  def test_clean_text_strips_html_bbcode_and_truncates
    assert_equal "Hola & mundo", Normalizer.clean_text("<p>Hola &amp; <b>mundo</b></p><script>x()</script>")
    assert_equal "Patch notas", Normalizer.clean_text("[h1]Patch[/h1] [img]{STEAM_CLAN_IMAGE}/a.png[/img] notas", bbcode: true)
    assert_operator Normalizer.clean_text("palabra " * 200).length, :<=, 501
  end

  def test_parse_date_variants
    assert Normalizer.parse_date("Thu, 05 Nov 2026 10:00:00 GMT").utc?
    assert_equal 10, Normalizer.parse_date("2026-11-05T10:00:00Z").hour
    assert_equal 2026, Normalizer.parse_date(1_793_872_800).year
    assert_nil Normalizer.parse_date("basura")
    assert_nil Normalizer.parse_date("2099-01-01T00:00:00Z")
  end

  def test_build_item_validation
    assert_nil Normalizer.build_item(source_key: "s", title: "", url: "https://a.com/x")
    assert_nil Normalizer.build_item(source_key: "s", title: "T", url: "no-url")
    assert_nil Normalizer.build_item(source_key: "s", title: "T", url: "https://a.com/x").description
  end

  def test_rss_and_atom_parse
    entries = RssAdapter.parse_feed(rss(rss_item("Hola", "https://a.com/1", img: "https://a.com/i.jpg")))
    assert_equal "Ana", entries[0]["author"]
    assert_equal "https://a.com/i.jpg", entries[0]["image"]
    assert_equal ["News"], entries[0]["categories"]
    atom = <<~XML
      <feed xmlns="http://www.w3.org/2005/Atom"><entry><title>T</title><id>1</id>
      <link rel="alternate" href="https://a.com/a"/><updated>2026-11-05T10:00:00Z</updated>
      <author><name>Bo</name></author><summary>S &lt;img src="https://a.com/p.png"&gt;</summary></entry></feed>
    XML
    e = RssAdapter.parse_feed(atom)[0]
    assert_equal "https://a.com/a", e["link"]
    assert_equal "Bo", e["author"]
    assert_equal "https://a.com/p.png", e["image"]
  end

  def test_bad_or_malicious_xml
    ["<rss><item>", "no es xml",
     '<!DOCTYPE x [<!ENTITY a "b">]><rss><channel><item><title>&a;</title></item></channel></rss>'].each do |body|
      assert_raises(AdapterError) { RssAdapter.parse_feed(body) }
    end
  end

  def test_classifier
    it = Normalizer.build_item(source_key: "ign", title: "Nvidia RTX 5090 GPU benchmark leaks", url: "https://a.com/1", description: "Runs on PC and Xbox")
    c = Classifier.classify(it)
    assert_includes c.categories, "hardware"
    assert_equal %w[pc xbox], c.platforms & %w[pc xbox]
    assert c.version
    d = Classifier.classify(Normalizer.build_item(source_key: "ign", title: "Something about a game", url: "https://a.com/2"))
    assert_equal ["gaming"], d.categories
    assert_includes Classifier.classify(Normalizer.build_item(source_key: "nintendolife", title: "Mario news", url: "https://a.com/3")).platforms, "nintendo"
  end

  def test_clean_text_accepts_non_string_values
    assert_equal "Ana, Bo", Normalizer.clean_text(%w[Ana Bo], 120)
    assert_equal "Ana", Normalizer.clean_text({ "name" => "Ana" }, 120)
    assert_equal "123", Normalizer.clean_text(123)
    assert_nil Normalizer.clean_text({})
    assert_nil Normalizer.clean_text([])
    assert_nil Normalizer.clean_text(true)
    assert_nil Normalizer.canonicalize_url(123)
  end

  def test_parse_newsmesh_tolerates_non_string_fields
    body = JSON.generate({ "articles" => [
      { "title" => "Hola", "link" => "https://a.com/1", "author" => %w[Ana Bo], "source" => { "name" => "IGN" }, "category" => "gaming" },
      { "title" => ["Dos"], "url" => "https://a.com/2", "author" => { "name" => "Cy" }, "description" => 5, "source" => ["x"] }
    ] })
    items = NewsMeshAdapter.parse(body, "newsmesh")
    assert_equal ["Ana, Bo", "Cy"], items.map(&:author)
    assert_equal "IGN", items[0].extra["publisher"]
    assert_nil items[1].extra["publisher"]
  end

  def test_title_key_and_unicode_helpers
    assert_equal "big studio announces brand new game today", Normalizer.title_key("Big studio announces brand-new game today!")
    assert_equal "cafe nino", Normalizer.title_key("Café  Niño")
    assert_equal "©", Normalizer.unescape("&copy;")
    assert_equal "é", Normalizer.unescape("&#233;")
  end
end
