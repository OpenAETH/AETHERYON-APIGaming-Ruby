# frozen_string_literal: true

require "cgi"
require "nokogiri"

module Aetheryon
  # Normalización: URLs canónicas, fechas, texto limpio, claves de título, construcción de items.
  module Normalizer
    TRACKING_KEYS = %w[fbclid gclid igshid ocid cmpid ref_src mc_cid mc_eid].freeze
    EXCERPT_MAX = 500
    SCRIPT = %r{<(script|style)[^>]*>.*?</\1>}mi
    TAG = /<[^>]+>/
    BBCODE = /\[\/?[a-zA-Z0-9_*]+(?:[=\s][^\]]*)?\]/
    BB_IMG = %r{\[img[^\]]*\].*?\[/img\]}mi
    IMG_SRC = /<img[^>]+src=["']([^"']+)["']/i
    URL_SPLIT = %r{\A(?:([a-zA-Z][a-zA-Z0-9+.\-]*):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:\#(.*))?\z}m
    SAFE_QUOTE = /[A-Za-z0-9_.\-~]/

    module_function

    def tracking?(key)
      k = key.downcase
      k.start_with?("utm_") || TRACKING_KEYS.include?(k)
    end

    # urlsplit tolerante (como urllib): devuelve [scheme, netloc, path, query, fragment]
    def urlsplit(url)
      m = URL_SPLIT.match(url) or return ["", "", url, "", ""]
      scheme = m[1] ? m[1].downcase : ""
      [scheme, m[2] || "", m[3] || "", m[4] || "", m[5] || ""]
    end

    def unquote(s)
      s.b.gsub(/%([0-9a-fA-F]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding("UTF-8").scrub("\uFFFD")
    end

    def quote_plus(s)
      s.b.gsub(/[^A-Za-z0-9_.\-~ ]/n) { |ch| format("%%%02X", ch.ord) }.tr(" ", "+").force_encoding("UTF-8")
    end

    def parse_qsl(query)
      query.split("&").filter_map do |pair|
        next if pair.empty?

        k, v = pair.split("=", 2)
        [unquote(k.tr("+", " ")), unquote((v || "").tr("+", " "))]
      end
    end

    def canonicalize_url(url)
      return nil if url.nil? || !url.is_a?(String) || url.empty?

      url = Util.py_strip(url)
      url = "https:#{url}" if url.start_with?("//")
      scheme, netloc, path, query, = urlsplit(url)
      return nil unless %w[http https].include?(scheme) && !netloc.empty?

      host = netloc.downcase.sub(/:(80|443)\z/, "")
      host = host[4..] if host.start_with?("www.")
      path = path.gsub(%r{/{2,}}, "/")
      path = "/" if path.empty?
      path = path.sub(%r{/+\z}, "") if path.length > 1
      q = parse_qsl(query).reject { |k, _| tracking?(k) }.sort
      qs = q.map { |k, v| "#{quote_plus(k)}=#{quote_plus(v)}" }.join("&")
      "https://#{host}#{path}#{qs.empty? ? '' : "?#{qs}"}"
    end

    # URL válida http(s) para mostrar (imagen/enlace); nil si es inválida.
    def clean_url(url)
      return nil if url.nil? || !url.is_a?(String) || url.empty?

      url = Util.py_strip(url)
      url = "https:#{url}" if url.start_with?("//")
      scheme, netloc, = urlsplit(url)
      %w[http https].include?(scheme) && !netloc.empty? ? url : nil
    end

    # Coacciona valores de APIs externas (str, lista, dict, número) a texto; nil si no hay texto útil.
    def as_text(raw)
      case raw
      when nil, true, false then nil
      when String then raw
      when Integer, Float then raw.to_s
      when Array
        parts = raw.map { |x| as_text(x) }.reject { |p| p.nil? || p.empty? }
        parts.empty? ? nil : parts.join(", ")
      when Hash
        %w[name title text value label].each do |k|
          v = as_text(raw[k])
          return v if v && !v.empty?
        end
        nil
      end
    end

    NAMED = { "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'", "nbsp" => "\u00A0" }.freeze

    # html.unescape
    def unescape(t)
      t.gsub(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/) do |m|
        ent = Regexp.last_match(1)
        if ent.start_with?("#")
          cp = ent[1].downcase == "x" ? ent[2..].hex : ent[1..].to_i
          cp.zero? || cp > 0x10FFFF || (0xD800..0xDFFF).cover?(cp) ? "\uFFFD" : [cp].pack("U")
        elsif NAMED.key?(ent)
          NAMED[ent]
        else
          d = Nokogiri::HTML4::EntityLookup.new.get(ent)
          d ? [d.value].pack("U") : m
        end
      end
    end

    def clean_text(raw, max_len = EXCERPT_MAX, bbcode: false)
      raw = as_text(raw)
      return nil if raw.nil? || raw.empty?

      t = raw.gsub(SCRIPT, " ")
      if bbcode
        t = t.gsub(BB_IMG, " ")
        t = t.gsub(BBCODE, " ")
      end
      t = t.gsub(TAG, " ")
      t = unescape(t)
      t = t.gsub(TAG, " ") # contenido doblemente codificado
      t = Util.collapse_ws(t)
      return nil if t.empty?

      if t.length > max_len
        cut = t[0, max_len]
        i = cut.rindex(" ")
        cut = cut[0, i] if i
        t = "#{cut.sub(/[,.;:\- ]+\z/, '')}…"
      end
      t
    end

    def first_image_in_html(raw)
      return nil if raw.nil? || raw.empty?

      m = IMG_SRC.match(raw)
      m ? clean_url(unescape(m[1])) : nil
    end

    def parse_date(value)
      return nil if value.nil? || value == ""

      dt =
        begin
          if value.is_a?(Time)
            value.getutc
          elsif value.is_a?(Numeric) || (value.is_a?(String) && value.strip.match?(/\A\d+\z/))
            ts = Float(value)
            Time.at(ts > 1e12 ? ts / 1000 : ts).utc
          else
            s = Util.py_strip(value.to_s)
            begin
              Time.rfc2822(s).getutc
            rescue ArgumentError
              Util.parse_iso(s)
            end
          end
        rescue ArgumentError, RangeError, FloatDomainError, TypeError
          return nil
        end
      return nil if dt > Time.now.utc + 86_400 # fecha futura incoherente

      dt
    end

    def title_key(title)
      t = Util.fold(title)
      t = t.gsub(/[^[:word:][:space:]]/, " ")
      Util.collapse_ws(t)
    end

    # Valida y normaliza. Devuelve nil si falta título o URL válida (item descartado).
    def build_item(source_key:, title:, url:, description: nil, published: nil, image: nil, author: nil, external_id: nil,
                   categories: nil, tags: nil, game_appid: nil, platform_hint: nil, extra: nil, bbcode: false)
      title = clean_text(title, 300)
      canon = canonicalize_url(url)
      return nil if title.nil? || canon.nil?

      NormalizedItem.new(
        source_key: source_key, title: title, url: clean_url(url) || canon, canonical_url: canon, title_key: title_key(title),
        description: clean_text(description, bbcode: bbcode), published_at: parse_date(published), image_url: clean_url(image),
        author: clean_text(author, 120), external_id: external_id.nil? || external_id == "" ? nil : external_id.to_s,
        source_categories: uniq(categories), source_tags: uniq(tags), game_appid: game_appid, platform_hint: platform_hint,
        extra: extra || {}
      )
    end

    def uniq(values)
      seen = {}
      (values || []).filter_map do |v|
        v = clean_text(v.to_s, 80)
        next if v.nil? || seen[v.downcase]

        seen[v.downcase] = true
        v
      end
    end
  end
end
