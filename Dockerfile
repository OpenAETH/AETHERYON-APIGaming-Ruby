FROM ruby:4.0-slim
ENV DATA_DIR=/data BUNDLE_WITHOUT=test BUNDLE_DEPLOYMENT=1 PORT=8000
WORKDIR /srv
# libpq para el gem pg; build-essential solo si algún gem no trae binario precompilado.
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 libpq-dev build-essential curl \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .
RUN useradd -r -u 10001 aetheryon && mkdir /data && chown aetheryon /data
USER aetheryon
VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8000/health || exit 1
# Un solo proceso (workers 0): el scheduler corre dentro del proceso (evita recolecciones duplicadas).
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
