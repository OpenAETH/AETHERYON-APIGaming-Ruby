# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "aetheryon"

# Arranque: `bundle exec puma -C config/puma.rb` (un solo proceso: el scheduler corre dentro).
application = Aetheryon::Application.new
application.start!
at_exit { application.shutdown! }
run application
