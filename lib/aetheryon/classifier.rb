# frozen_string_literal: true

module Aetheryon
  # Clasificación temática por reglas. El resultado se guarda aparte de los datos originales.
  module Classifier
    VERSION = "rules-v1"
    CATEGORIES = %w[gaming releases industry esports hardware technology indie updates off_topic].freeze

    RULES = {
      "releases" => ['release dates?', 'releas(?:e|es|ed|ing)', 'launch(?:es|ed|ing)?', 'out now', 'pre-?orders?',
                     'coming (?:to|soon)', 'available now', 'lanzamiento', 'estreno', 'fecha de salida'],
      "industry" => ['layoffs?', 'laid off', 'acquisitions?', 'acquir(?:es|ed|ing)', 'publisher', 'earnings', 'revenue',
                     'lawsuit', 'union(?:s|ize|ise)?', 'ceo', 'merger', 'shuts? down', 'closure', 'funding', 'investors?',
                     'ftc', 'regulators?', 'despidos', 'adquisici[oó]n'],
      "esports" => ['esports?', 'tournaments?', 'championships?', 'world finals?', 'grand finals?', 'vct', 'lcs', 'lec', 'evo', 'torneo'],
      "hardware" => ['gpus?', 'graphics cards?', 'rtx', 'radeon', 'ryzen', 'cpus?', 'handhelds?', 'steam deck', 'rog ally',
                     'controllers?', 'headsets?', 'monitors?', 'ssds?', 'ram', 'ps5 pro', 'switch 2', 'gaming pc', 'benchmarks?', 'keyboards?'],
      "technology" => ['ai', 'artificial intelligence', 'generative', 'machine learning', 'cloud gaming', 'ray tracing', 'dlss',
                       'fsr', 'unreal engine', 'unity', 'game engine', 'drivers?', 'streaming'],
      "indie" => ['indie', 'solo dev(?:eloper)?', 'kickstarter', 'itch\.io', 'devlog'],
      "updates" => ['patch(?:es)?', 'patch notes', 'hotfix', 'updates?', 'season \d+', 'dlc', 'expansions?', 'balance changes',
                    'version \d+(?:\.\d+)*', 'actualizaci[oó]n', 'parche']
    }.freeze
    COMPILED = RULES.transform_values { |p| Regexp.new("\\b(?:#{p.join('|')})\\b", Regexp::IGNORECASE) }.freeze

    PLATFORMS = {
      "pc" => 'pc|steam|windows|epic games store|gog',
      "playstation" => 'ps5|ps4|psvr2?|playstation(?: ?[345])?',
      "xbox" => 'xbox(?: series [xs]| one)?|game pass',
      "nintendo" => 'nintendo(?: switch(?: 2)?)?|switch 2|switch online|eshop|wii u|3ds',
      "mobile" => 'ios|android|iphone|mobile (?:game|gaming)s?',
      "vr" => 'meta quest|quest [23]|vr|virtual reality|valve index'
    }.freeze
    PLAT_COMPILED = PLATFORMS.transform_values { |p| Regexp.new("\\b(?:#{p})\\b", Regexp::IGNORECASE) }.freeze
    SOURCE_HINTS = { "nintendolife" => "nintendo", "rockpapershotgun" => "pc", "pcgamer" => "pc", "steam" => "pc" }.freeze

    Classification = Struct.new(:categories, :tags, :platforms, :confidence, :rule_method, :version, keyword_init: true) do
      def initialize(**kw) = super(rule_method: "rules", version: VERSION, **kw)
    end

    module_function

    def classify(item)
      title = item.title
      desc = item.description || ""
      scores = {}
      tags = []

      add = lambda do |cat, text, weight|
        text.scan(COMPILED[cat]) do
          scores[cat] = scores.fetch(cat, 0) + weight
          t = Regexp.last_match[0].downcase
          tags << t unless tags.include?(t)
        end
      end

      COMPILED.each_key do |cat|
        add.call(cat, title, 2)
        add.call(cat, desc, 1)
      end
      scores["updates"] = scores.fetch("updates", 0) + 3 if item.source_tags.any? { |t| t.downcase == "patchnotes" }

      # orden estable por puntaje descendente (empates: orden de aparición)
      cats = scores.each_with_index.sort_by { |(_, s), i| [-s, i] }.map { |(c, _), _| c }.first(3)
      cats = ["gaming"] if cats.empty?

      text = "#{title} #{desc}"
      plats = PLAT_COMPILED.select { |_, rx| rx.match?(text) }.keys
      hint = item.platform_hint || SOURCE_HINTS[item.source_key]
      plats << hint if hint && !plats.include?(hint)

      total = scores.values.sum
      conf = scores.empty? ? 0.2 : [0.95, (0.35 + 0.1 * total).round(2)].min
      Classification.new(categories: cats, tags: tags.first(8), platforms: plats, confidence: conf)
    end
  end
end
