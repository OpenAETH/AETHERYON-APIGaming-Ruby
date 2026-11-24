# frozen_string_literal: true

module Aetheryon
  # Aplica las migraciones pendientes: `bundle exec rake migrate`. Usar en el deploy, no en cada arranque serverless.
  module Migrate
    module_function

    def main
      s = Settings.from_env
      url = ENV["DATABASE_URL_UNPOOLED"].to_s.empty? ? s.database_url : ENV["DATABASE_URL_UNPOOLED"] # DDL: mejor la conexión directa de Neon
      applied = Database.new(url, s.db_schema).migrate
      puts "Migraciones aplicadas: #{applied.empty? ? 'ninguna (esquema al día)' : applied.inspect}"
      0
    end
  end
end
