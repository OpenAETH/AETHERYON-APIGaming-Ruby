# frozen_string_literal: true

module Aetheryon
  # Control de cuotas diarias por proveedor (persistente, atómico, día UTC).
  class QuotaManager
    def initialize(db) = @db = db

    def today = Time.now.utc.strftime("%Y-%m-%d")

    def used(provider)
      @db.conn do |c|
        r = c.execute("SELECT count FROM quota_usage WHERE provider=? AND day=?", [provider, today]).fetchone
        r ? r["count"] : 0
      end
    end

    # Reserva n solicitudes si no se supera (limit - reserve). Atómico entre procesos (un solo statement).
    def try_consume(provider, limit, reserve = 0, n = 1)
      cap = [0, limit - reserve].max
      return false if n > cap

      @db.conn do |c|
        r = c.execute(
          "INSERT INTO quota_usage(provider, day, count) VALUES(?,?,?) " \
          "ON CONFLICT(provider, day) DO UPDATE SET count = quota_usage.count + EXCLUDED.count " \
          "WHERE quota_usage.count + EXCLUDED.count <= ? RETURNING count",
          [provider, today, n, cap]
        ).fetchone
        !r.nil?
      end
    end
  end
end
