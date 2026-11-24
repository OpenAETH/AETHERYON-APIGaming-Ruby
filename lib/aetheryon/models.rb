# frozen_string_literal: true

module Aetheryon
  # Contrato interno uniforme entre adaptadores, normalizador y almacenamiento.
  NormalizedItem = Struct.new(
    :source_key, :title, :url, :canonical_url, :title_key, :description, :published_at, :image_url, :author,
    :external_id, :source_categories, :source_tags, :game_appid, :platform_hint, :extra, keyword_init: true
  ) do
    def initialize(**kw)
      super(description: nil, published_at: nil, image_url: nil, author: nil, external_id: nil,
            source_categories: [], source_tags: [], game_appid: nil, platform_hint: nil, extra: {}, **kw)
    end
  end
end
