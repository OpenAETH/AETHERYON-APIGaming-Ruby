# frozen_string_literal: true

module Aetheryon
  # Helpers de fidelidad con Python (strip/split Unicode, isoformat, repr de listas, truthiness).
  module Util
    WS = "[[:space:]]"

    module_function

    def py_strip(s) = s.gsub(/\A#{WS}+|#{WS}+\z/, "")
    def py_split(s) = s.split(/#{WS}+/).reject(&:empty?)
    def collapse_ws(s) = py_strip(s.gsub(/#{WS}+/, " "))

    def truthy?(v)
      !(v.nil? || v == false || v == 0 || v == "" || v == [] || v == {} || v == 0.0)
    end

    def utcnow = Time.now.utc

    # datetime.isoformat() para un datetime UTC: fracción solo si hay microsegundos.
    def iso(t, timespec: nil)
      t = t.getutc
      base = t.strftime("%Y-%m-%dT%H:%M:%S")
      frac = timespec == "seconds" || t.usec.zero? ? "" : format(".%06d", t.usec)
      "#{base}#{frac}+00:00"
    end

    def utcnow_iso = iso(utcnow, timespec: "seconds")

    ISO_RE = /\A(\d{4})-?(\d{2})-?(\d{2})(?:[T ](\d{2})(?::?(\d{2})(?::?(\d{2})(?:[.,](\d{1,9}))?)?)?)?[[:space:]]*(Z|z|[+-]\d{2}(?::?\d{2})?)?\z/

    # datetime.fromisoformat: devuelve Time (UTC) o lanza ArgumentError. Sin zona => UTC.
    def parse_iso(s)
      m = ISO_RE.match(s.to_s.strip) or raise ArgumentError, "Invalid isoformat string: #{s.inspect}"
      y, mo, d, h, mi, se, fr, tz = m.captures
      usec = fr ? fr.ljust(6, "0")[0, 6].to_i : 0
      t = Time.utc(y.to_i, mo.to_i, d.to_i, (h || 0).to_i, (mi || 0).to_i, (se || 0).to_i, usec)
      if tz && !tz.match?(/\A[Zz]\z/)
        sign = tz[0] == "-" ? -1 : 1
        digits = tz[1..].delete(":")
        off = digits[0, 2].to_i * 3600 + digits[2, 2].to_i * 60
        t -= sign * off
      end
      t
    end

    def py_list_repr(list) = "[" + list.map { |x| "'#{x}'" }.join(", ") + "]"

    def fold(t)
      s = t.downcase
      s = s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "") unless s.ascii_only?
      s
    end
  end
end
