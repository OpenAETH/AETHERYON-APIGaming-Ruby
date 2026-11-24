# frozen_string_literal: true

require_relative "test_helper"

class TestDb < Minitest::Test
  include PgTest

  def test_translate_placeholders_and_literals
    assert_equal "SELECT '?' , a FROM t WHERE x=$1 AND y ILIKE $2 ESCAPE '\\'",
                 Conn.translate("SELECT '?' , a FROM t WHERE x=? AND y ILIKE ? ESCAPE '\\'")
    assert_equal "SELECT '100%' WHERE a=$1", Conn.translate("SELECT '100%' WHERE a=?")
  end

  def test_row_access_by_name_and_index
    r = Row["a" => 1, "b" => "x"]
    assert_equal 1, r["a"]
    assert_equal 1, r[0]
    assert_equal [1, "x"], r.values
  end

  def test_migrate_is_idempotent
    assert_equal [], db.migrate
    n = db.conn { |c| c.execute("SELECT COUNT(*) FROM schema_migrations").fetchone[0] }
    assert_equal MIGRATIONS.size, n
  end

  def test_quota_cap_and_reserve
    q = QuotaManager.new(db)
    assert_equal [true, true, false], Array.new(3) { q.try_consume("p", 3, 1) }
    assert_equal 2, q.used("p")
    assert_equal false, q.try_consume("p", 3, 1, 5)
    assert_equal false, q.try_consume("zero", 2, 2)
  end

  def test_quota_is_atomic_under_concurrency
    q = QuotaManager.new(db)
    wins = Array.new(25) { Thread.new { q.try_consume("c", 10, 0) } }.map(&:value)
    assert_equal 10, wins.count(true)
    assert_equal 10, q.used("c")
  end

  def test_ingest_is_serialized_across_threads
    db.conn { |c| c.execute("INSERT INTO sources(key, name, kind) VALUES('s1','S1','rss'),('s2','S2','rss')") }
    res = %w[s1 s2 s1 s2 s1 s2 s1 s2].map do |k|
      Thread.new { Store.ingest(db, [Normalizer.build_item(source_key: k, title: "Same exact headline with many words", url: "https://a.com/same")]) }
    end.map(&:value)
    assert_equal 1, res.sum(&:new)
    assert_equal 1, count("articles")
  end

  def test_search_is_case_insensitive_and_escapes_wildcards
    db.conn { |c| c.execute("INSERT INTO sources(key, name, kind) VALUES('s','S','rss')") }
    Store.ingest(db, [Normalizer.build_item(source_key: "s", title: "Zelda Tears of the Kingdom review 100% done", url: "https://a.com/z")])
    total = ->(q) { Repository.list_articles(db, Repository::Filters.new(q: q), 1, 10)["total"] }
    assert_equal 1, total.call("zelda")
    assert_equal 1, total.call("100%")
    assert_equal 1, total.call("%")
    assert_equal 0, total.call("zz%zz")
  end

  def test_commit_on_nonlocal_return_and_rollback_on_error
    db.conn { |c| c.execute("INSERT INTO sources(key, name, kind) VALUES('a','A','rss')") }
    assert_raises(RuntimeError) do
      db.conn do |c|
        c.execute("INSERT INTO sources(key, name, kind) VALUES('b','B','rss')")
        raise "boom"
      end
    end
    assert_equal 1, count("sources")
  end
end
