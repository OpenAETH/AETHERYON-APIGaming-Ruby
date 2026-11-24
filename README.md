# AETHERYON Gaming News API (Ruby)

Port a Ruby (Sinatra + Puma + PostgreSQL) de la API original en FastAPI. Mismo contrato HTTP, mismo esquema de base de datos
y mismas reglas de dominio (normalización, clasificación, deduplicación, cuotas, pipeline editorial con Groq).
**Terra Gazette consume esta API, nunca a los proveedores.**

## Requisitos
Ruby ≥ 3.2 (probado el desarrollo sobre 3.2; objetivo 4.0.10), Bundler, PostgreSQL ≥ 13 (usa `FOR UPDATE SKIP LOCKED` y advisory locks).

## Arranque rápido (Windows / Linux)
```bash
bundle install
cp .env.example .env        # completar DATABASE_URL y ADMIN_API_KEY (y NEWSMESH_API_KEY / GROQ_API_KEY si corresponde)
bundle exec rake migrate    # opcional: el arranque normal ya migra solo (salvo SERVERLESS=true)
bundle exec puma -C config/puma.rb     # http://localhost:8000
# Docker
docker compose up -d --build
```
- Swagger UI: `/docs` · ReDoc: `/redoc` · OpenAPI: `/openapi.json` · Panel de fuentes: `/panel` · Healthcheck: `/health`
- **Un solo proceso de Puma** (`workers 0`, ya configurado): el scheduler y el worker editorial viven dentro del proceso.
- Tests (requieren PostgreSQL; cada test usa un schema efímero):
  `docker run -d -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=aetheryon_test -p 5432:5432 postgres:16`
  `bundle exec rake test` (otra base: `TEST_DATABASE_URL=postgresql://…`)

## Equivalencias con la versión Python
| Python | Ruby |
|---|---|
| FastAPI + uvicorn | Sinatra + Puma (`config.ru`, `config/puma.rb`) |
| asyncio / httpx | hilos (`Thread`) / `Net::HTTP` (`lib/aetheryon/http.rb`) |
| psycopg 3 | gem `pg` (envoltorio `Conn` con placeholders `?`) |
| defusedxml / ElementTree | Nokogiri estricto, sin red, rechaza entidades DTD |
| Pydantic / OpenAPI automático | validación manual con el mismo formato de errores 422 + `lib/aetheryon/openapi.rb` |
| `python -m app.migrate` | `bundle exec rake migrate` |

Notas de comportamiento:
- Errores: `{"detail": ...}` (igual que FastAPI), incluida la forma `[{type, loc, msg, input, ctx}]` en los 422.
- `lib/aetheryon/openapi.rb` es el contrato OpenAPI declarado a mano (Sinatra no lo genera): al agregar una ruta, documentarla ahí.
- Vercel: no se portó `index.py`/`vercel.json` (el despliegue Ruby en Vercel no está resuelto). `SERVERLESS=true` sigue disponible
  (colección en línea, sin scheduler) pero para producción se recomienda Docker/VM con un solo proceso + `.github/workflows/collect.yml` si hace falta cron externo.

## Estructura
```
config.ru · config/puma.rb · Rakefile · Gemfile
lib/aetheryon/  config db models classifier normalizer quota store repository http games registry collector
                adapters/{base,rss,newsmesh,steam}  editorial/{prompts,validate,groq,queue,worker,processed}
                validation errors openapi cors app migrate  static/panel.html
test/           51+ tests (minitest + rack-test) · examples/terra_gazette_client.rb · docs/
```
Para el resto de la documentación funcional (pipeline editorial, endpoints, fuentes) ver `docs/PROVIDERS.md` y los documentos
`docs/RUBY_PORT_SPEC.md` / `docs/RUBY_PORT_CHARACTERIZATION.md`.
