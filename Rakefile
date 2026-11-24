# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/test_*.rb"
  t.warning = false
end

desc "Aplica las migraciones pendientes (usar en el deploy)"
task :migrate do
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "aetheryon"
  exit Aetheryon::Migrate.main
end

task default: :test
