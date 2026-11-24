# frozen_string_literal: true

require "nokogiri"

module Aetheryon
  # Adaptador RSS/Atom genérico: una instancia por medio (cada feed es una fuente independiente).
  class RssAdapter < SourceAdapter
    def initialize(key, name, url)
      super()
      @key = key
      @name = name
      @url = url
      @kind = "rss"
    end

    def min_interval_min(settings) = settings.rss_min_interval_min

    # Texto directo del elemento (hasta el primer hijo elemento), como ElementTree.text.
    def self.own_text(el)
      out = +""
      el.children.each do |n|
        break if n.element?

        out << n.content if n.text? || n.cdata?
      end
      out
    end

    def self.child_elements(el) = el.element_children

    def self.text(el, *names)
      child_elements(el).each do |c|
        next unless names.include?(c.name)

        t = Util.py_strip(own_text(c))
        return t unless t.empty?
      end
      nil
    end

    def self.link(el)
      child_elements(el).each do |c|
        next unless c.name == "link"

        href = c["href"]
        return href if href && !href.empty? && (c["rel"] || "alternate") == "alternate" # Atom
        t = Util.py_strip(own_text(c))
        return t unless t.empty? # RSS
      end
      nil
    end

    def self.image(el, html_blobs)
      el.xpath(".//*").each do |c|
        n = c.name
        return c["url"] if n == "thumbnail" && c["url"] && !c["url"].empty?
        return c["url"] if n == "content" && c["url"] && !c["url"].empty? && (c["medium"] == "image" || (c["type"] || "").start_with?("image"))
        return c["url"] if n == "enclosure" && c["url"] && !c["url"].empty? && (c["type"] || "").start_with?("image")
      end
      html_blobs.each do |b|
        img = Normalizer.first_image_in_html(b)
        return img if img
      end
      nil
    end

    def self.parse_feed(body)
      doc =
        begin
          Nokogiri::XML(body) { |cfg| cfg.strict.nonet.nodtdload }
        rescue Nokogiri::XML::SyntaxError
          raise AdapterError, "XML inválido o no permitido: ParseError"
        end
      if doc.internal_subset&.children&.any? { |n| n.type == Nokogiri::XML::Node::ENTITY_DECL }
        raise AdapterError, "XML inválido o no permitido: EntitiesForbidden"
      end
      raise AdapterError, "XML inválido o no permitido: ParseError" if doc.root.nil?

      doc.root.xpath("descendant-or-self::*").select { |e| %w[item entry].include?(e.name) }.map do |e|
        desc_raw = text(e, "description", "summary")
        content_raw = text(e, "encoded", "content")
        cats = child_elements(e).select { |c| c.name == "category" }.filter_map do |c|
          v = c["term"]
          v = Util.py_strip(own_text(c)) if v.nil? || v.empty?
          v unless v.empty?
        end
        author = text(e, "creator", "author")
        if author.nil? # Atom: <author><name>
          child_elements(e).each { |c| author = text(c, "name") if c.name == "author" }
        end
        {
          "title" => text(e, "title"), "link" => link(e), "guid" => text(e, "guid", "id"),
          "published" => text(e, "pubDate", "published", "updated", "date"),
          "description" => desc_raw || content_raw, "author" => author, "categories" => cats,
          "image" => image(e, [content_raw, desc_raw])
        }
      end
    end

    def fetch(ctx)
      body, cached = Http.cached_get(
        ctx, "rss:#{key}", url, ttl_s: ctx.settings.rss_min_interval_min * 60,
        headers: { "Accept" => "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5" }
      )
      entries = self.class.parse_feed(body)
      res = FetchResult.new(requests_made: cached ? 0 : 1)
      skipped = 0
      entries.each do |e|
        item = Normalizer.build_item(
          source_key: key, title: e["title"], url: e["link"], description: e["description"], published: e["published"],
          image: e["image"], author: e["author"], external_id: e["guid"], categories: e["categories"]
        )
        item.nil? ? skipped += 1 : res.items << item
      end
      res.warnings << "#{skipped} entradas descartadas por falta de título o enlace válido" if skipped.positive?
      raise AdapterError, "Feed sin entradas (formato no reconocido o vacío)" if entries.empty?

      res
    end
  end
end
