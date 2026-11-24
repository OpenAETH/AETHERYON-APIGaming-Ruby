# frozen_string_literal: true

require "set"

module Aetheryon
  module Editorial
    # Validación determinista de la salida del LLM: estructura, límites y fidelidad (cifras y entidades verificables).
    module Validate
      ENTITY_TYPES = %w[person character organization developer publisher game franchise platform product hardware
                        service place real_location fictional_location event].freeze
      LIMITS = { "title" => 160, "summary" => 450, "body" => 1500 }.freeze # topes duros: se rechaza, nunca se trunca
      MIN_SOURCE_CHARS = 40

      class ValidationError < StandardError; end

      Result = Struct.new(:source_language, :translated, :title, :summary, :body, :category, :categories, :entities,
                          :uncertainty, :insufficient_info, :dropped_entities)

      module_function

      def fold(t) = Util.fold(t)

      # Cifras como cadenas de dígitos ('$1,999' y '1.999' → '1999'): independiente del formato regional.
      def numbers(text)
        text.scan(/\p{Nd}[\p{Nd}.,]*/).map { |m| m.gsub(/\P{Nd}/, "") }.reject(&:empty?).to_set
      end

      def text_field(data, key, single_line: true)
        v = data[key]
        raise ValidationError, "Campo '#{key}' ausente o vacío" if !v.is_a?(String) || Util.py_strip(v).empty?

        v = single_line ? Util.py_split(v).join(" ") : Util.py_strip(v.gsub(/[ \t]+/, " "))
        raise ValidationError, "'#{key}' supera #{LIMITS[key]} caracteres (#{v.length})" if v.length > LIMITS[key]

        v
      end

      def parse_output(raw, source_title, source_desc, categories, fallback_category)
        t = Util.py_strip(raw).sub(/\A```(?:json)?[[:space:]]*/, "").sub(/[[:space:]]*```\z/, "")
        data =
          begin
            JSON.parse(t)
          rescue JSON::ParserError, TypeError
            raise ValidationError, "La respuesta no es JSON válido"
          end
        raise ValidationError, "La respuesta JSON no es un objeto" unless data.is_a?(Hash)

        title = text_field(data, "title")
        summary = text_field(data, "summary")
        body = text_field(data, "body", single_line: false)
        source_text = "#{source_title}\n#{source_desc || ''}"

        extra = numbers("#{title} #{summary} #{body}") - numbers(source_text)
        raise ValidationError, "Cifras que no figuran en el texto original: #{Util.py_list_repr(extra.to_a.sort.first(5))}" unless extra.empty?

        lang = Util.py_strip((data["source_language"] || "").to_s).downcase[0, 3]
        lang = "und" unless lang.match?(/\A[a-z]{2,3}\z/)

        cat = data["category"]
        cat = categories.include?(cat) ? cat : (categories.include?(fallback_category) ? fallback_category : categories[0])
        listed = data["categories"].is_a?(Array) ? data["categories"] : []
        cats = ([cat] + listed.select { |c| c.is_a?(String) && categories.include?(c) && c != cat }).uniq.first(4)

        folded_src = fold(source_text)
        entities = []
        dropped = []
        seen = Set.new
        (data["entities"].is_a?(Array) ? data["entities"] : []).each do |e|
          name = e.is_a?(Hash) ? e["name"] : nil
          next if !name.is_a?(String) || Util.py_strip(name).empty?

          name = Util.py_split(name).join(" ")
          unless folded_src.include?(fold(name)) # solo entidades verificables en el texto recibido
            dropped << name
            next
          end
          next if seen.include?(fold(name))

          seen << fold(name)
          entities << { "name" => name, "type" => ENTITY_TYPES.include?(e["type"]) ? e["type"] : "other" }
        end
        entities = entities.first(15)

        unc = (data["uncertainty"].is_a?(Array) ? data["uncertainty"] : [])
              .select { |u| u.is_a?(String) && !Util.py_strip(u).empty? }
              .map { |u| Util.py_split(u).join(" ")[0, 200] }.first(8)
        insufficient = Util.truthy?(data["insufficient_info"])
        if Util.py_strip(source_desc || "").length < MIN_SOURCE_CHARS
          insufficient = true
          unc << "La fuente no incluye un extracto suficiente: el contenido se limita al título."
        end
        Result.new(lang, Util.truthy?(data["translated"]), title, summary, body, cat, cats, entities, unc, insufficient, dropped)
      end
    end
  end
end
