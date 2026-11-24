# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "rack/test"
require "securerandom"
require "aetheryon"

Aetheryon::LOG.level = Logger::FATAL

include Aetheryon # rubocop:disable Style/MixinUsage

TEST_DB_URL = ENV.fetch("TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/aetheryon_test")

RSS_TMPL = <<~XML
  <?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"
   xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>x</title>
  %<items>s</channel></rss>
XML

def rss_item(title, link, desc: "<p>Texto con <b>HTML</b></p>", date: nil, guid: nil, img: nil)
  # fecha relativa a "ahora": los tests de ventanas (latest/trending/intake) no dependen del día de ejecución
  date ||= (Time.now.utc - 7200).strftime("%a, %d %b %Y %H:%M:%S GMT")
  "<item><title>#{title}</title><link>#{link}</link><guid>#{guid || link}</guid><pubDate>#{date}</pubDate>" \
    "<dc:creator>Ana</dc:creator><category>News</category><description><![CDATA[#{desc}]]></description>" +
    (img ? %(<media:thumbnail url="#{img}"/>) : "") + "</item>"
end

def rss(*items) = format(RSS_TMPL, items: items.join)

# Simula el cliente HTTP (equivalente a httpx.MockTransport).
FakeRequest = Struct.new(:method, :url, :host, :path, :params, :headers, :content)

class FakeHttp
  def initialize(&handler) = @handler = handler

  def get(url, params: nil, headers: {}, timeout: nil)
    call("GET", url, params, headers, nil)
  end

  def post_json(url, payload, headers: {}, timeout: nil)
    call("POST", url, nil, headers.merge("content-type" => "application/json"), JSON.generate(payload))
  end

  def close; end

  private

  def call(method, url, params, headers, content)
    uri = URI.parse(url)
    all = URI.decode_www_form(uri.query.to_s).to_h.merge((params || {}).to_h { |k, v| [k.to_s, v.to_s] })
    req = FakeRequest.new(method, url, uri.host, uri.path, all, headers.transform_keys(&:downcase), content)
    @handler.call(req)
  end
end

def http_resp(status, text: nil, json: nil, headers: {})
  HttpResponse.new(status, json ? JSON.generate(json) : text.to_s, headers)
end

# Cliente de pruebas sobre la app Rack.
class Client
  Res = Struct.new(:status, :body) do
    def json = JSON.parse(body)
  end

  def initialize(app) = @s = Rack::Test::Session.new(Rack::MockSession.new(app))

  def request(verb, path, params: nil, headers: {}, json: nil)
    path += "?#{URI.encode_www_form(params.map { |k, v| [k, v.to_s] })}" if params && !params.empty?
    env = headers.to_h { |k, v| ["HTTP_#{k.upcase.tr('-', '_')}", v] }
    if json.nil?
      @s.public_send(verb, path, nil, env)
    else
      env["CONTENT_TYPE"] = "application/json"
      @s.public_send(verb, path, JSON.generate(json), env)
    end
    Res.new(@s.last_response.status, @s.last_response.body)
  end

  %i[get post patch delete].each { |v| define_method(v) { |path, **kw| request(v, path, **kw) } }
end

module PgTest
  def setup
    super
    @schema = "t_#{SecureRandom.hex(6)}"
    admin { |c| c.exec("CREATE SCHEMA #{@schema}") }
    @tmp = Dir.mktmpdir
    @settings = Settings.new(database_url: TEST_DB_URL, db_schema: @schema, data_dir: @tmp, scheduler_enabled: false,
                             newsmesh_api_key: "SECRETKEY123")
    Editorial::GroqClient.sleeper = ->(_s) {}
  end

  def teardown
    admin { |c| c.exec("DROP SCHEMA #{@schema} CASCADE") }
    FileUtils.rm_rf(@tmp)
    Editorial::GroqClient.sleeper = nil
    super
  end

  def admin
    c = PG.connect(TEST_DB_URL)
    c.exec("SET client_min_messages=warning")
    yield c
  ensure
    c&.close
  end

  def settings = @settings

  def db
    @db ||= Database.new(settings.database_url, settings.db_schema).tap(&:init)
  end

  def count(table = "articles") = db.conn { |c| c.execute("SELECT COUNT(*) FROM #{table}").fetchone[0] }

  def fake_client(&h) = FakeHttp.new(&h)
end

require "tmpdir"
require "fileutils"
