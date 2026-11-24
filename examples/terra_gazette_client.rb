# frozen_string_literal: true

# Cliente de ejemplo para Terra Gazette: consume SOLO esta API, nunca a los proveedores externos.
#
# Las noticias son materia prima: se conservan fuente, URL, fecha e imagen para atribución, y nada se publica
# sin pasar por el proceso editorial de Terra Gazette.
require "json"
require "net/http"
require "uri"

class TerraGazetteClient
  # `http` puede ser cualquier objeto con get(path, params:) que devuelva un objeto con status y json
  # (los tests inyectan el cliente Rack); por defecto usa Net::HTTP contra base_url.
  def initialize(base_url: "http://localhost:8000", http: nil)
    @base_url = base_url
    @http = http
  end

  def candidates(category: nil, hours: 24, page_size: 20)
    params = { "hours" => hours, "page_size" => page_size }
    params["category"] = category if category
    r = get("/api/news/latest", params)
    raise "HTTP #{r.status}" unless r.status < 400

    r.json["items"].map { |a| self.class.to_editorial_record(a) }
  end

  # Registro de ingesta editorial con todo lo necesario para atribuir.
  def self.to_editorial_record(a)
    {
      "news_id" => a["id"],
      "headline_source" => a["title"],
      "summary_source" => a["description"],
      "attribution" => a["references"].map { |r| { "outlet" => r["source_name"] || r["source"], "url" => r["url"], "date" => r["published_at"] } },
      "primary_url" => a["url"],
      "published_at" => a["published_at"],
      "image_url" => a["image_url"],
      "categories" => a["categories"],
      "status" => "pending_editorial_review" # nunca auto-publicar
    }
  end

  private

  Resp = Struct.new(:status, :body) do
    def json = JSON.parse(body)
  end

  def get(path, params)
    return @http.get(path, params: params) if @http

    uri = URI.join(@base_url, path)
    uri.query = URI.encode_www_form(params)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 15) { |h| h.get(uri.request_uri) }
    Resp.new(res.code.to_i, res.body)
  end
end

if $PROGRAM_NAME == __FILE__
  TerraGazetteClient.new.candidates(category: "releases").each do |rec|
    puts "#{rec['headline_source']} -> #{rec['attribution'].map { |x| x['outlet'] }.inspect}"
  end
end
