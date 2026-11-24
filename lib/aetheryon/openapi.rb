# frozen_string_literal: true

module Aetheryon
  # Contrato OpenAPI 3.1 equivalente al que FastAPI generaba automáticamente. Sinatra no lo genera: se declara acá
  # y un test verifica que cada ruta real esté documentada.
  module OpenAPI
    DESCRIPTION = <<~TXT
      Agregador de noticias de videojuegos. Centraliza RSS (IGN, PC Gamer, GameSpot, Eurogamer, Kotaku, Rock Paper Shotgun,
      Nintendo Life), NewsMesh y Steam News en un esquema JSON uniforme, con deduplicación, caché, control de cuotas y trazabilidad.

      **Datos originales vs. generados:** `original` contiene lo que informó el proveedor; `categories`, `tags`, `platforms`
      y `classification` son generados por reglas. Los extractos están limitados a 500 caracteres: para el texto completo
      hay que ir a `url` (artículo original). Operaciones de escritura requieren header `X-API-Key`.
    TXT

    module_function

    def ref(n) = { "$ref" => "#/components/schemas/#{n}" }
    def opt(s) = { "anyOf" => [s, { "type" => "null" }] }
    def str = { "type" => "string" }
    def int = { "type" => "integer" }
    def num = { "type" => "number" }
    def bool = { "type" => "boolean" }
    def arr(s) = { "type" => "array", "items" => s }

    def obj(props, required = nil)
      titled = props.to_h { |k, v| [k, v.key?("title") ? v : v.merge("title" => k.split("_").map(&:capitalize).join(" "))] }
      { "type" => "object", "properties" => titled, "required" => required || props.keys }
    end

    def schemas
      page = ->(item, extra = {}) { obj({ "items" => arr(ref(item)), "page" => int, "page_size" => int, "total" => int, "pages" => int }.merge(extra)) }
      {
        "Reference" => obj({ "source" => str, "source_name" => opt(str), "url" => str, "published_at" => opt(str), "captured_at" => str },
                           %w[source url captured_at]),
        "ClassificationOut" => obj({ "method" => str, "version" => str, "confidence" => num, "generated_at" => str }),
        "Original" => obj({ "categories" => arr(str), "tags" => arr(str), "external_id" => opt(str), "extra" => { "type" => "object" } }, []),
        "GameRef" => obj({ "appid" => int, "name" => opt(str) }, ["appid"]),
        "SourceRef" => obj({ "key" => str, "name" => opt(str) }, ["key"]),
        "Article" => obj({
          "id" => str, "title" => str, "description" => opt(str), "source" => ref("SourceRef"), "url" => str, "canonical_url" => str,
          "published_at" => opt(str), "captured_at" => str, "image_url" => opt(str), "author" => opt(str),
          "categories" => arr(str), "tags" => arr(str), "platforms" => arr(str), "game" => opt(ref("GameRef")),
          "references" => arr(ref("Reference")), "original" => ref("Original"), "classification" => opt(ref("ClassificationOut")),
          "score" => opt(num)
        }, %w[id title source url canonical_url captured_at original]),
        "Page" => page.call("Article"),
        "GameCreate" => obj({ "name" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
                              "appid" => opt({ "type" => "integer", "exclusiveMinimum" => 0 }), "url" => opt(str),
                              "platform" => { "type" => "string", "default" => "pc" },
                              "status" => { "type" => "string", "enum" => %w[active paused], "default" => "active" },
                              "franchise" => opt({ "type" => "string", "minLength" => 1, "maxLength" => 100 }) }, ["name"]),
        "GameUpdate" => obj({ "name" => opt({ "type" => "string", "minLength" => 1, "maxLength" => 200 }),
                              "appid" => opt({ "type" => "integer", "exclusiveMinimum" => 0 }), "url" => opt(str), "platform" => opt(str),
                              "status" => opt({ "type" => "string", "enum" => %w[active paused] }),
                              "franchise" => opt({ "type" => "string", "minLength" => 1, "maxLength" => 100 }) }, []),
        "CollectRequest" => obj({ "sources" => opt(arr(str)), "force" => { "type" => "boolean", "default" => true } }, []),
        "Entity" => obj({ "name" => str, "type" => str }),
        "EditorialOut" => obj({ "language" => str, "source_language" => str, "translated" => bool, "title" => str, "summary" => str,
                                "body" => str, "category" => str, "categories" => arr(str), "entities" => arr(ref("Entity")),
                                "uncertainty" => arr(str), "insufficient_info" => bool }),
        "NormalizedOut" => obj({ "title" => str, "description" => opt(str), "categories" => arr(str), "tags" => arr(str),
                                 "platforms" => arr(str), "classification" => opt(ref("ClassificationOut")) }, ["title"]),
        "Tokens" => obj({ "prompt" => int, "completion" => int }),
        "ProcessingOut" => obj({ "model" => str, "pipeline_version" => str, "content_hash" => str, "generated_at" => str,
                                 "attempts" => int, "tokens" => ref("Tokens") }),
        "ProcessedItem" => obj({
          "id" => str, "status" => { "type" => "string", "const" => "completed" }, "url" => str, "canonical_url" => str,
          "published_at" => opt(str), "captured_at" => str, "image_url" => opt(str), "author" => opt(str),
          "source" => ref("SourceRef"), "game" => opt(ref("GameRef")), "references" => arr(ref("Reference")),
          "original" => ref("Original"), "normalized" => ref("NormalizedOut"), "editorial" => ref("EditorialOut"),
          "processing" => ref("ProcessingOut")
        }, %w[id status url canonical_url captured_at source original normalized editorial processing]),
        "ProcessedPage" => page.call("ProcessedItem"),
        "QueueItem" => obj({
          "id" => str, "title" => str, "source" => ref("SourceRef"),
          "status" => { "type" => "string", "enum" => %w[pending processing completed failed] }, "priority" => int,
          "attempts" => int, "max_attempts" => int, "enqueued_by" => str, "pipeline_version" => str, "enqueued_at" => str,
          "started_at" => opt(str), "finished_at" => opt(str), "next_attempt_at" => opt(str), "last_error" => opt(str)
        }, %w[id title source status priority attempts max_attempts enqueued_by pipeline_version enqueued_at]),
        "QueuePage" => page.call("QueueItem", { "counts" => { "type" => "object", "additionalProperties" => int },
                                                "usage_today" => { "type" => "object", "additionalProperties" => int },
                                                "worker" => { "type" => "object" } }),
        "SpanishItem" => obj({
          "id" => str, "language" => { "type" => "string", "const" => "es" }, "title" => str, "summary" => str, "body" => str,
          "category" => str, "categories" => arr(str), "entities" => arr(ref("Entity")), "uncertainty" => arr(str),
          "insufficient_info" => bool, "translated" => bool, "source_language" => str, "original_title" => str, "url" => str,
          "source" => ref("SourceRef"), "published_at" => opt(str), "image_url" => opt(str), "author" => opt(str),
          "game" => opt(ref("GameRef")), "references" => arr(ref("Reference")), "generated_at" => str, "model" => str
        }, %w[id language title summary body category categories entities uncertainty insufficient_info translated
              source_language original_title url source generated_at model]),
        "SpanishPage" => page.call("SpanishItem", { "pending" => int }),
        "ValidationError" => obj({ "loc" => arr({ "anyOf" => [str, int] }), "msg" => str, "type" => str }),
        "HTTPValidationError" => obj({ "detail" => arr(ref("ValidationError")) }, [])
      }
    end

    # ---- descripción de parámetros ----
    def qp(name, schema, required: false, desc: nil)
      p = { "name" => name, "in" => "query", "required" => required, "schema" => schema }
      p["description"] = desc if desc
      p
    end

    SRC = "Fuente(s), repetible: ?source=ign&source=kotaku. Incluye medios que citan la misma noticia."

    def news_filters(dates: true)
      [qp("source", opt(arr(str)), desc: SRC), qp("category", opt(arr(str)), desc: "Categoría(s) generada(s)"),
       qp("platform", opt(arr(str)), desc: "Plataforma(s): pc, playstation, xbox, nintendo, mobile, vr"),
       qp("game", opt(int), desc: "AppID de Steam")] +
        (dates ? [qp("date_from", opt({ "type" => "string", "format" => "date-time" })), qp("date_to", opt({ "type" => "string", "format" => "date-time" }))] : [])
    end

    def paging = [qp("page", { "type" => "integer", "minimum" => 1, "default" => 1 }), qp("page_size", { "type" => "integer", "maximum" => 100, "minimum" => 1, "default" => 20 })]
    def path_param(name, schema = str) = { "name" => name, "in" => "path", "required" => true, "schema" => schema }

    # [método, ruta, nombre_funcion, resumen, tag, parámetros, cuerpo, status_ok, schema_respuesta, auth, oculta]
    def routes
      dt = { "type" => "string", "format" => "date-time" }
      ed_dates = [qp("date_from", opt(dt)), qp("date_to", opt(dt))]
      [
        ["get", "/api/news/processed", "processed", "Noticias procesadas (versión editorial lista para consumir)", "editorial",
         [qp("source", opt(arr(str)), desc: SRC), qp("category", opt(arr(str)), desc: "Categoría(s) editorial(es)"),
          qp("language", opt(arr(str)), desc: "Idioma ORIGINAL de la noticia (ISO 639-1: en, es, pt…). El texto editorial siempre es español.")] + ed_dates + paging,
         nil, "200", ref("ProcessedPage")],
        ["get", "/api/news/es", "spanish", "Noticias en español (traducidas y con redacción editorial)", "editorial",
         [qp("source", opt(arr(str)), desc: "Fuente(s), repetible"), qp("category", opt(arr(str)), desc: "Categoría(s) editorial(es)"),
          qp("translated", opt(bool), desc: "true: solo traducidas desde otro idioma; false: solo las que ya estaban en español")] + ed_dates + paging,
         nil, "200", ref("SpanishPage")],
        ["get", "/api/news/queue", "queue_list", "Cola de procesamiento editorial", "editorial",
         [qp("status", opt({ "type" => "string", "enum" => %w[pending processing completed failed] }))] + paging, nil, "200", ref("QueuePage")],
        ["post", "/api/news/{article_id}/process", "process_one", "Solicitar el procesamiento de una noticia", "editorial",
         [path_param("article_id"), qp("force", bool.merge("default" => false), desc: "Reprocesa aunque ya esté completada"),
          qp("wait", bool.merge("default" => false), desc: "Procesa en línea y responde con el resultado")], nil, "202", ref("QueueItem"), true],
        ["get", "/api/news", "list_news", "Noticias combinadas (paginadas)", "news", news_filters + paging, nil, "200", ref("Page")],
        ["get", "/api/news/latest", "latest", "Últimas publicaciones", "news",
         news_filters(dates: false) + [qp("hours", { "type" => "integer", "maximum" => 720, "minimum" => 1, "default" => 48 }, desc: "Ventana de tiempo")] + paging,
         nil, "200", ref("Page")],
        ["get", "/api/news/trending", "trending", "Tendencias", "news",
         [qp("hours", { "type" => "integer", "maximum" => 168, "minimum" => 1, "default" => 48 }),
          qp("limit", { "type" => "integer", "maximum" => 100, "minimum" => 1, "default" => 20 }),
          qp("category", opt(arr(str)), desc: "Categoría(s) generada(s)"),
          qp("platform", opt(arr(str)), desc: "Plataforma(s): pc, playstation, xbox, nintendo, mobile, vr")], nil, "200", arr(ref("Article"))],
        ["get", "/api/news/search", "search", "Búsqueda por texto (título y extracto)", "news",
         [qp("q", { "type" => "string", "maxLength" => 100, "minLength" => 2 }, required: true)] + news_filters + paging, nil, "200", ref("Page")],
        ["get", "/api/news/{article_id}", "detail", "Detalle con todas las referencias", "news", [path_param("article_id")], nil, "200", ref("Article")],
        ["get", "/api/games/franchises", "list_franchises", "Franquicias registradas y cantidad de juegos", "games", [], nil, "200", { "type" => "array", "items" => { "type" => "object" } }],
        ["get", "/api/games", "list_games", "Catálogo de juegos", "games",
         [qp("status", opt({ "type" => "string", "pattern" => "^(active|paused|unresolved)$" })),
          qp("franchise", opt({ "type" => "string", "maxLength" => 100, "minLength" => 1 }))], nil, "200", {}],
        ["get", "/api/games/steam-search", "steam_search", "Buscar en el catálogo público de Steam (mejor esfuerzo)", "games",
         [qp("q", { "type" => "string", "minLength" => 2 }, required: true)], nil, "200", {}],
        ["get", "/api/games/{game_id}", "get_game", "Get Game", "games", [path_param("game_id", int)], nil, "200", {}],
        ["post", "/api/games", "create_game", "Registrar juego (AppID manual, por URL de Steam o por nombre)", "games", [], ref("GameCreate"), "201", {}, true],
        ["patch", "/api/games/{game_id}", "update_game", "Editar juego / cargar AppID manualmente", "games", [path_param("game_id", int)], ref("GameUpdate"), "200", {}, true],
        ["post", "/api/games/{game_id}/resolve", "retry_resolve", "Reintentar resolución automática del AppID", "games", [path_param("game_id", int)], nil, "200", {}, true],
        ["delete", "/api/games/{game_id}", "delete_game", "Delete Game", "games", [path_param("game_id", int)], nil, "204", nil, true],
        ["get", "/health", "health", "Healthcheck", "operations", [], nil, "200", {}],
        ["get", "/api/categories", "categories", "Categorías con cantidad de noticias", "operations", [], nil, "200", {}],
        ["get", "/api/sources", "sources", "Fuentes y su estado", "operations", [], nil, "200", {}],
        ["post", "/api/sources/{key}/pause", "pause", "Pausar fuente", "operations", [path_param("key")], nil, "200", {}, true],
        ["post", "/api/sources/{key}/enable", "enable", "Activar fuente", "operations", [path_param("key")], nil, "200", {}, true],
        ["post", "/api/sources/{key}/test", "test_source", "Probar un adaptador sin guardar resultados", "operations", [path_param("key")], nil, "200", {}, true],
        ["post", "/api/collect", "collect", "Iniciar recolección manual", "operations", [], ref("CollectRequest"), "202", {}, true],
        ["get", "/api/sync/status", "sync_status", "Estado de sincronización", "operations", [], nil, "200", {}],
        ["get", "/api/sync/runs", "runs", "Historial de sincronizaciones", "operations",
         [qp("limit", { "type" => "integer", "maximum" => 100, "minimum" => 1, "default" => 20 })], nil, "200", {}],
        ["get", "/api/sync/runs/{run_id}", "run_detail", "Detalle de una sincronización", "operations", [path_param("run_id", int)], nil, "200", {}],
        ["get", "/api/cron/process", "cron_process", "Procesamiento editorial de la cola (intake + lote)", "cron",
         [qp("batch", opt({ "type" => "integer", "maximum" => 20, "minimum" => 1 }))], nil, "200", {}, true],
        ["post", "/api/cron/process", "cron_process", "Cron Process", "cron", [qp("batch", opt({ "type" => "integer", "maximum" => 20, "minimum" => 1 }))],
         nil, "200", {}, true, :hidden],
        ["get", "/api/cron/collect", "cron_collect", "Recolección programada (respeta el intervalo mínimo de cada fuente)", "cron",
         [qp("source", opt(arr(str))), qp("force", bool.merge("default" => false))], nil, "200", {}, true],
        ["post", "/api/cron/collect", "cron_collect", "Cron Collect", "cron", [qp("source", opt(arr(str))), qp("force", bool.merge("default" => false))],
         nil, "200", {}, true, :hidden]
      ]
    end

    # Pares [método, ruta] de las rutas documentadas y ocultas (las ocultas existen pero no figuran en el esquema).
    def route_table = routes.map { |r| [r[0].upcase, r[1], r[10] == :hidden] }

    def build
      paths = {}
      routes.each do |method, path, name, summary, tag, params, body, ok, resp, secured, hidden|
        next if hidden == :hidden

        has_validation = !params.empty? || body
        responses = { ok => { "description" => ok == "204" ? "Successful Response" : "Successful Response" } }
        responses[ok]["content"] = { "application/json" => { "schema" => resp } } if resp
        responses["422"] = { "description" => "Validation Error", "content" => { "application/json" => { "schema" => ref("HTTPValidationError") } } } if has_validation
        op = { "tags" => [tag], "summary" => summary, "operationId" => "#{name}#{path.gsub(/\W/, '_')}_#{method}", "responses" => responses }
        op["parameters"] = params unless params.empty?
        if body
          content = { "application/json" => { "schema" => path == "/api/collect" ? opt(body) : body } }
          op["requestBody"] = path == "/api/collect" ? { "content" => content } : { "content" => content, "required" => true }
        end
        op["security"] = [{ "APIKeyHeader" => [] }] if secured && !path.start_with?("/api/cron")
        (paths[path] ||= {})[method] = op
      end
      {
        "openapi" => "3.1.0",
        "info" => { "title" => "AETHERYON Gaming News API", "description" => DESCRIPTION, "version" => VERSION },
        "paths" => paths,
        "components" => { "schemas" => schemas, "securitySchemes" => { "APIKeyHeader" => { "type" => "apiKey", "in" => "header", "name" => "X-API-Key" } } }
      }
    end

    def swagger_html
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <link type="text/css" rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
        <link rel="shortcut icon" href="https://fastapi.tiangolo.com/img/favicon.png">
        <title>AETHERYON Gaming News API - Swagger UI</title>
        </head>
        <body>
        <div id="swagger-ui">
        </div>
        <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
        <script>
        const ui = SwaggerUIBundle({
            url: '/openapi.json',
        "dom_id": "#swagger-ui",
        "layout": "BaseLayout",
        "deepLinking": true,
        "showExtensions": true,
        "showCommonExtensions": true,
        presets: [
            SwaggerUIBundle.presets.apis,
            SwaggerUIBundle.SwaggerUIStandalonePreset
            ],
        })
        </script>
        </body>
        </html>
      HTML
    end

    def redoc_html
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <title>AETHERYON Gaming News API - ReDoc</title>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link href="https://fonts.googleapis.com/css?family=Montserrat:300,400,700|Roboto:300,400,700" rel="stylesheet">
        <style>body { margin: 0; padding: 0; }</style>
        </head>
        <body>
        <noscript>ReDoc requires Javascript to function. Please enable it to browse the documentation.</noscript>
        <redoc spec-url="/openapi.json"></redoc>
        <script src="https://cdn.jsdelivr.net/npm/redoc@2/bundles/redoc.standalone.js"> </script>
        </body>
        </html>
      HTML
    end
  end
end
