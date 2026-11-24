# frozen_string_literal: true

require "rack"

module Aetheryon
  # Validación de query/path/body con los mismos límites y mensajes (formato Pydantic v2) que FastAPI.
  module Validation
    module_function

    def err(type, loc, msg, input, ctx = nil)
      h = { "type" => type, "loc" => loc, "msg" => msg, "input" => input }
      h["ctx"] = ctx if ctx
      h
    end

    def parse_int(s)
      return Integer(Util.py_strip(s), 10) if s.is_a?(String) && Util.py_strip(s).match?(/\A[+-]?\d+\z/)

      nil
    end

    def parse_bool(s)
      case s.to_s.downcase
      when "1", "true", "t", "yes", "y", "on" then true
      when "0", "false", "f", "no", "n", "off" then false
      end
    end

    # datetime ISO 8601 (o epoch); sin zona => UTC. nil si no es válido.
    def parse_datetime(s)
      s = Util.py_strip(s)
      return Time.at(s.to_i).utc if s.match?(/\A\d{9,}\z/)

      Util.parse_iso(s)
    rescue ArgumentError, RangeError
      nil
    end

    # Lectura tipada de parámetros (query o path) acumulando errores como FastAPI.
    class Params
      attr_reader :errors

      def initialize(query_string, where = "query")
        @raw = begin
          Rack::Utils.parse_query(query_string.to_s)
        rescue StandardError
          {}
        end
        @where = where
        @errors = []
      end

      def values(name) = @raw.key?(name) ? Array(@raw[name]) : nil
      def value(name) = values(name)&.last

      def add(type, name, msg, input, ctx = nil) = @errors << Validation.err(type, [@where, name], msg, input, ctx)

      def list(name) = values(name)

      def str(name, required: false, min: nil, max: nil, pattern: nil)
        v = value(name)
        if v.nil?
          add("missing", name, "Field required", nil) if required
          return nil
        end
        if min && v.length < min
          add("string_too_short", name, "String should have at least #{min} character#{'s' unless min == 1}", v, { "min_length" => min })
        elsif max && v.length > max
          add("string_too_long", name, "String should have at most #{max} character#{'s' unless max == 1}", v, { "max_length" => max })
        elsif pattern && !v.match?(pattern)
          add("string_pattern_mismatch", name, "String should match pattern '#{pattern.source.gsub('\A', '^').gsub('\z', '$')}'", v,
              { "pattern" => pattern.source.gsub('\A', "^").gsub('\z', "$") })
        end
        v
      end

      def int(name, default: nil, ge: nil, le: nil)
        v = value(name)
        return default if v.nil?

        n = Validation.parse_int(v)
        if n.nil?
          add("int_parsing", name, "Input should be a valid integer, unable to parse string as an integer", v)
          return default
        end
        if ge && n < ge
          add("greater_than_equal", name, "Input should be greater than or equal to #{ge}", v, { "ge" => ge })
        elsif le && n > le
          add("less_than_equal", name, "Input should be less than or equal to #{le}", v, { "le" => le })
        end
        n
      end

      def bool(name, default: nil)
        v = value(name)
        return default if v.nil?

        b = Validation.parse_bool(v)
        add("bool_parsing", name, "Input should be a valid boolean, unable to interpret input", v) if b.nil?
        b.nil? ? default : b
      end

      def datetime(name)
        v = value(name)
        return nil if v.nil?

        t = Validation.parse_datetime(v)
        add("datetime_from_date_parsing", name, "Input should be a valid datetime or date, invalid character in year", v) if t.nil?
        t
      end

      def literal(name, allowed)
        v = value(name)
        return nil if v.nil?

        unless allowed.include?(v)
          quoted = allowed.map { |a| "'#{a}'" }
          expected = quoted.length > 1 ? "#{quoted[0..-2].join(', ')} or #{quoted[-1]}" : quoted[0]
          add("literal_error", name, "Input should be #{expected}", v, { "expected" => expected })
        end
        v
      end

      def finish! = (raise ValidationFailed, @errors unless @errors.empty?)
    end

    # ---- cuerpo JSON ----
    def parse_body(raw, required:)
      if raw.nil? || Util.py_strip(raw).empty?
        raise ValidationFailed, [err("missing", ["body"], "Field required", nil)] if required

        return nil
      end
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise ValidationFailed, [err("json_invalid", ["body", 0], "JSON decode error", {}, { "error" => e.message[0, 120] })]
    end

    def model_error(data) = ValidationFailed.new([err("model_attributes_type", ["body"], "Input should be a valid dictionary or object to extract fields from", data)])

    def check_str(errors, key, v, min: nil, max: nil)
      unless v.is_a?(String)
        errors << err("string_type", ["body", key], "Input should be a valid string", v)
        return false
      end
      if min && v.length < min
        errors << err("string_too_short", ["body", key], "String should have at least #{min} character#{'s' unless min == 1}", v, { "min_length" => min })
        return false
      end
      if max && v.length > max
        errors << err("string_too_long", ["body", key], "String should have at most #{max} characters", v, { "max_length" => max })
        return false
      end
      true
    end

    def check_appid(errors, v)
      n = case v
          when Integer then v
          when Float then v == v.floor ? v.to_i : nil
          when String then parse_int(v)
          end
      if n.nil? || v == true || v == false
        type = v.is_a?(String) ? "int_parsing" : (v.is_a?(Float) ? "int_from_float" : "int_type")
        errors << err(type, ["body", "appid"], v.is_a?(String) ? "Input should be a valid integer, unable to parse string as an integer" : "Input should be a valid integer", v)
        return nil
      end
      unless n.positive?
        errors << err("greater_than", ["body", "appid"], "Input should be greater than 0", v, { "gt" => 0 })
        return nil
      end
      n
    end

    def check_literal(errors, key, v, allowed)
      return true if allowed.include?(v)

      q = allowed.map { |a| "'#{a}'" }
      exp = "#{q[0..-2].join(', ')} or #{q[-1]}"
      errors << err("literal_error", ["body", key], "Input should be #{exp}", v, { "expected" => exp })
      false
    end

    # GameCreate / GameUpdate. create=true aplica defaults y exige name; false devuelve solo los campos enviados.
    def game_model(data, create:)
      raise model_error(data) unless data.is_a?(Hash)

      errors = []
      out = {}
      if data.key?("name")
        v = data["name"]
        if !create && v.nil?
          out["name"] = nil
        elsif check_str(errors, "name", v, min: 1, max: 200)
          out["name"] = v
        end
      elsif create
        errors << err("missing", ["body", "name"], "Field required", nil)
      end
      if data.key?("appid")
        v = data["appid"]
        out["appid"] = v.nil? ? nil : check_appid(errors, v)
      elsif create
        out["appid"] = nil
      end
      if data.key?("url")
        v = data["url"]
        out["url"] = v if v.nil? || check_str(errors, "url", v)
      elsif create
        out["url"] = nil
      end
      if data.key?("platform")
        v = data["platform"]
        out["platform"] = v if (!create && v.nil?) || check_str(errors, "platform", v)
      elsif create
        out["platform"] = "pc"
      end
      if data.key?("status")
        v = data["status"]
        out["status"] = v if (!create && v.nil?) || check_literal(errors, "status", v, %w[active paused])
      elsif create
        out["status"] = "active"
      end
      if data.key?("franchise")
        v = data["franchise"]
        out["franchise"] = v if v.nil? || check_str(errors, "franchise", v, min: 1, max: 100)
      elsif create
        out["franchise"] = nil
      end
      raise ValidationFailed, errors unless errors.empty?

      out
    end

    def collect_request(data)
      return { "sources" => nil, "force" => true } if data.nil?
      raise model_error(data) unless data.is_a?(Hash)

      errors = []
      sources = data["sources"]
      if sources && !sources.is_a?(Array)
        errors << err("list_type", ["body", "sources"], "Input should be a valid list", sources)
      elsif sources
        sources.each_with_index { |s, i| errors << err("string_type", ["body", "sources", i], "Input should be a valid string", s) unless s.is_a?(String) }
      end
      force = true
      if data.key?("force")
        f = data["force"]
        force = f == true || f == false ? f : (f.is_a?(String) || f.is_a?(Integer) ? parse_bool(f) : nil)
        if force.nil?
          errors << err("bool_parsing", ["body", "force"], "Input should be a valid boolean, unable to interpret input", f)
          force = true
        end
      end
      raise ValidationFailed, errors unless errors.empty?

      { "sources" => sources, "force" => force }
    end
  end
end
