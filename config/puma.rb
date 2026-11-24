# frozen_string_literal: true

# Un solo proceso (sin workers): el scheduler y el worker editorial corren dentro del proceso.
port ENV.fetch("PORT", 8000)
threads 2, Integer(ENV.fetch("PUMA_THREADS", 16))
workers 0
