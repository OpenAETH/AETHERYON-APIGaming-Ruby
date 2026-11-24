# frozen_string_literal: true

require "json"
require "time"
require "logger"

module Aetheryon
  VERSION = "1.0.0"

  LOG = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, t, prog, msg| "#{t.utc.strftime('%Y-%m-%d %H:%M:%S,%L')} #{sev} #{prog || 'app'}: #{msg}\n" }
    l.level = Logger::INFO
  end

  def self.log(name = "app") = LOG.tap { |l| l.progname = name }
end

%w[util config db models classifier normalizer quota store repository http games
   adapters/base adapters/rss adapters/newsmesh adapters/steam registry collector
   editorial/prompts editorial/validate editorial/groq editorial/queue editorial/worker editorial/processed
   errors validation openapi cors app migrate].each { |f| require_relative "aetheryon/#{f}" }
