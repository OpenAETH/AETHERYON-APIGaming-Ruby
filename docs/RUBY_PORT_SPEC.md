# RUBY_PORT_SPEC.md
## AETHERYON Gaming API · Inventario de equivalencia HTTP

- **Base de referencia:** `main` (implementación Python + FastAPI).
- **Rama de trabajo:** `ruby-port`.
- **Objetivo:** implementar una API Ruby/Sinatra paralela que preserve los contratos HTTP consumidos por el panel, TerraGazette, automatizaciones y clientes externos.
- **Regla de seguridad:** este documento y toda implementación Ruby se escriben únicamente en `ruby-port`. No modificar `main`, secretos, base productiva ni despliegues actuales.
- **Estado:** inventario estático de rutas y contratos visibles en código. Los contratos deben validarse luego con pruebas de caracterización contra la API Python.

### Convenciones

- **Admin:** header `X-API-Key`, validado por `require_admin`. Si no hay `ADMIN_API_KEY`, escritura queda abierta fuera de producción y devuelve 503 en producción. Clave ausente/incorrecta con clave configurada: 401.
- **Cron:** header `Authorization: Bearer <CRON_SECRET>`. Si no hay secreto: 503. Credencial incorrecta/ausente: 401. No sustituir por la clave admin.
- **Paginación:** `page=1`, `page_size=20`, mínimo 1, máximo 100, salvo que se indique otra cosa.
- **Fechas:** parámetros datetime ISO; las fechas sin zona se interpretan como UTC y se normalizan a UTC.
- **Filtros repetibles:** `source`, `category` y `platform` pueden enviarse más de una vez.
- **Respuestas:** JSON salvo rutas de panel/redirección y respuestas explícitamente indicadas.
- **No asumir:** no se fijan aquí detalles SQL, nombres de tablas, semántica de errores internos ni comportamiento no expuesto por los routers.

## 1. Salud, raíz y documentación

| Método | Ruta | Auth | Entrada | Respuesta / comportamiento |
|---|---|---|---|---|
| GET | `/` | No | — | Redirección HTTP a `/docs`. |
| GET | `/health` | No | — | `{"status":"ok"}` tras ejecutar `SELECT 1`; fallo DB debe seguir siendo fallo de healthcheck. |
| GET | `/panel` | No | — | Sirve el HTML estático del panel existente. Mantenerlo, no reconstruirlo. |
| GET | `/docs` | No | — | Swagger UI generado por FastAPI. Sinatra deberá servir documentación equivalente explícitamente. |
| GET | `/openapi.json` | No | — | Esquema OpenAPI generado por FastAPI. Ruby deberá exponer contrato equivalente. |

## 2. Noticias públicas · `/api/news`

Todas las rutas de esta sección son públicas, salvo que el router Python no añade dependencia de autenticación.

| Método | Ruta | Parámetros | Respuesta / reglas |
|---|---|---|---|
| GET | `/api/news` | `source*`, `category*`, `platform*`, `game` (AppID entero), `date_from`, `date_to`, `page`, `page_size` | Objeto Page: `items`, `page`, `page_size`, `total`, `pages`. Items Article. |
| GET | `/api/news/latest` | Los filtros anteriores salvo fechas; `hours` default 48, rango 1..720; paginación | Page. Convierte `hours` en fecha mínima UTC. |
| GET | `/api/news/trending` | `hours` default 48, rango 1..168; `limit` default 20, rango 1..100; `category*`, `platform*` | Array de Article ordenados por tendencia/score. |
| GET | `/api/news/search` | `q` requerido, 2..100 caracteres; filtros de news; fechas y paginación | Page. Búsqueda en título y extracto según README. |
| GET | `/api/news/{article_id}` | ID string en path | Article completo con referencias; 404 `Noticia no encontrada` si no existe. |

**Validaciones y normalización:**
- Categorías deben pertenecer al catálogo `CATEGORIES`; desconocidas devuelven 422 e informan las categorías válidas.
- Plataformas se normalizan a minúsculas.
- Extractos de noticias limitados a 500 caracteres según contrato general del servicio.
- `original` representa datos del proveedor; `categories`, `tags`, `platforms` y `classification` son generados por reglas.
- La deduplicación no elimina cobertura de otros medios: se conserva en `references`.

## 3. Pipeline editorial · prefijo `/api/news`

Estas rutas se registran **antes** de `news.router`. Es obligatorio mantener precedencia para que `/{article_id}` no capture rutas estáticas como `/es`, `/queue` o `/processed`.

| Método | Ruta | Auth | Parámetros | Respuesta / reglas |
|---|---|---|---|---|
| GET | `/api/news/processed` | No | `source*`, `category*`, `language*` (idioma original), `date_from`, `date_to`, paginación | ProcessedPage. Solo estado `completed`; contiene `original`, `normalized`, `editorial` y `processing` (modelo, versión, hash, tokens). |
| GET | `/api/news/es` | No | `source*`, `category*`, `translated` (bool), `date_from`, `date_to`, paginación | SpanishPage: items aplanados con `title`, `summary`, `body` en español, `original_title`, `url`, `references`; agrega `pending`. Solo noticias completed. |
| GET | `/api/news/queue` | No | `status` ∈ pending/processing/completed/failed; paginación | QueuePage: items, totales, contadores por estado, consumo LLM diario y estado del worker. |
| POST | `/api/news/{article_id}/process` | Admin | Query `force=false`, `wait=false` | Encola con prioridad 100. 202 si queda pendiente/en proceso; 200 si termina en completed/failed o si ya estaba procesada. 503 si Groq deshabilitado; 404 si artículo inexistente. Body no requerido. |

**Contrato editorial importante:** no alterar el registro original ni las noticias base; conservar separadas las capas `original`, `normalized` y `editorial`. El endpoint `/es` es la vista plana estable que consume TerraGazette.

## 4. Catálogo de juegos · `/api/games`

| Método | Ruta | Auth | Entrada | Respuesta / reglas |
|---|---|---|---|---|
| GET | `/api/games` | No | `status` opcional: active/paused/unresolved; `franchise` opcional, 1..100 caracteres | Array de juegos ordenados por nombre. `franchise=unassigned` filtra juegos sin franquicia; comparación de franquicia case-insensitive. |
| GET | `/api/games/franchises` | No | — | Array `{name,count}` por franquicia no vacía. |
| GET | `/api/games/steam-search` | No | `q` requerido, mínimo 2 caracteres | Resultados del catálogo público Steam, mejor esfuerzo. 503 si catálogo no disponible; mensaje indica carga manual de AppID. |
| GET | `/api/games/{game_id}` | No | `game_id` entero | Registro del juego; 404 `Juego no encontrado`. |
| POST | `/api/games` | Admin | GameCreate JSON | 201. Acepta `name` requerido (1..200), `appid` opcional >0, `url`, `platform` default pc, `status` active/paused default active, `franchise` opcional (1..100). Resuelve AppID por manual, URL Steam o nombre; si no resuelve, estado unresolved. Devuelve juego + `resolved` + `candidates`. 409 si AppID duplicado. |
| PATCH | `/api/games/{game_id}` | Admin | GameUpdate JSON parcial | Actualiza campos enviados; admite AppID manual o extraído de URL. Si pasa de unresolved a tener AppID, activa por defecto. Plataforma lowercase. 404 si no existe; 409 si AppID duplicado. |
| POST | `/api/games/{game_id}/resolve` | Admin | — | Reintenta resolución por nombre/URL; devuelve `resolved`, `appid`, `method`, `candidates`. Si resuelve, guarda AppID y activa. 404 si juego inexistente; 409 por AppID duplicado. |
| DELETE | `/api/games/{game_id}` | Admin | — | Elimina el juego; 204 sin body. 404 si no existe. |

**GameCreate / GameUpdate:** conservar nombres de campos, tipos, defaults y validaciones. No convertir el ID interno del juego en AppID: `game_id` identifica el registro y `appid` identifica el juego en Steam.

## 5. Operaciones y fuentes

| Método | Ruta | Auth | Entrada | Respuesta / reglas |
|---|---|---|---|---|
| GET | `/api/categories` | No | — | Categorías con cantidad de noticias. |
| GET | `/api/sources` | No | — | Fuentes y estado; incluye razón de indisponibilidad, intervalo mínimo y cuota de NewsMesh cuando aplica. |
| POST | `/api/sources/{key}/pause` | Admin | `key` en path | `{key,enabled:false}`; actualiza enabled=false y status=paused. 404 si fuente desconocida. |
| POST | `/api/sources/{key}/enable` | Admin | `key` en path | `{key,enabled:true}`; actualiza enabled=true y status=pending. 404 si fuente desconocida. |
| POST | `/api/sources/{key}/test` | Admin | `key` en path | Ejecuta adaptador sin persistir artículos. Devuelve `ok`, `status`, `error` o `fetched`, `requests`, `warnings`, `sample` (máximo 3). Puede consumir cuota NewsMesh si no hay caché vigente. Fuente desconocida: 404. |
| POST | `/api/collect` | Admin | Body opcional CollectRequest: `sources` array opcional, `force` default true | 202 normalmente: `run_id`, `status`, `status_url`. 409 si ya hay recolección. 422 si alguna fuente no existe. En serverless corre en línea y devuelve 200 con `run`. |
| GET | `/api/sync/status` | No | — | `running`, `total_articles`, `scheduler_enabled`, `last_run`. |
| GET | `/api/sync/runs` | No | `limit` default 20, rango 1..100 | Array con historial reciente de ejecuciones. |
| GET | `/api/sync/runs/{run_id}` | No | `run_id` entero | Detalle de ejecución. 404 si ejecución no encontrada. |

**CollectRequest:** `sources: string[] | null`; `force: boolean` default true. No asumir que ausencia de body equivale a `force=false`.

## 6. Cron externo · prefijo `/api/cron`

Todos los endpoints requieren exclusivamente autenticación Cron Bearer.

| Método | Ruta | Auth | Parámetros | Respuesta / reglas |
|---|---|---|---|---|
| GET | `/api/cron/collect` | Cron | `source*`, `force=false` | Corre recolección en línea. 200 con `{ok:true,run}`; si ya está corriendo 200 `{ok:true,skipped:"already_running"}`; 422 fuente desconocida; 502 si la corrida falla. |
| POST | `/api/cron/collect` | Cron | Igual que GET | Mismo comportamiento. En FastAPI está oculto del OpenAPI (`include_in_schema=false`), pero es una ruta funcional. |
| GET | `/api/cron/process` | Cron | `batch` opcional, 1..20 | Ejecuta intake + lote editorial en línea. Si Groq está deshabilitado devuelve `{ok:true,skipped:"groq_not_configured"}`; si no, `{ok:true,...resultado}`. |
| POST | `/api/cron/process` | Cron | Igual que GET | Mismo comportamiento. Oculto del OpenAPI actual, pero funcional. |

## 7. Resumen de autenticación y exposición

| Grupo | Lectura | Escritura / ejecución |
|---|---|---|
| Salud, panel, docs | Pública | — |
| Noticias | Pública | `POST /api/news/{id}/process` requiere Admin |
| Pipeline editorial | GET público | — |
| Juegos | GET público | POST, PATCH, DELETE y resolve requieren Admin |
| Operaciones | GET público | Pause, enable, test y collect requieren Admin |
| Cron | — | Bearer Cron obligatorio para GET y POST |

No aplicar Admin globalmente a todos los routers: las rutas GET actuales son públicas. No aceptar `X-API-Key` como sustituto de `CRON_SECRET`.

## 8. Contratos JSON principales

### Article
Campos documentados por el schema: `id`, `title`, `description`, `source`, `url`, `canonical_url`, `published_at`, `captured_at`, `image_url`, `author`, `categories`, `tags`, `platforms`, `game`, `references`, `original`, `classification`, `score`.

- `source`: `key`, `name?`.
- `game`: `appid`, `name?`.
- `references[]`: `source`, `source_name?`, `url`, `published_at?`, `captured_at`.
- `original`: `categories[]`, `tags[]`, `external_id?`, `extra{}`.
- `classification`: `method`, `version`, `confidence`, `generated_at`.

### Page
`{items: Article[], page: number, page_size: number, total: number, pages: number}`.

### Editorial
- ProcessedPage: items ProcessedItem + paginación.
- ProcessedItem: `id`, `status="completed"`, `url`, `canonical_url`, fechas, imagen, autor, source, game, references, original, normalized, editorial, processing.
- SpanishPage: items SpanishItem + paginación + `pending`.
- QueuePage: items QueueItem + paginación + `counts`, `usage_today`, `worker`.

## 9. Requisitos de equivalencia para Sinatra

1. Mantener las rutas y métodos exactamente, incluidos los POST de cron aunque hoy no aparezcan en OpenAPI.
2. Preservar códigos HTTP: 200, 201, 202, 204, 401, 404, 409, 422, 502 y 503 según cada caso.
3. Mantener los nombres JSON, tipos, valores por defecto, arrays vacíos/null y estructura anidada.
4. Preservar filtros repetibles y la semántica de fechas UTC.
5. Replicar autenticación Admin y Cron como dos middlewares/helpers independientes.
6. Registrar rutas estáticas de `/api/news` antes de `/api/news/:article_id`; idem rutas estáticas de juegos antes de `/api/games/:game_id`.
7. Mantener `/panel` y sus endpoints consumidos por el HTML: `/api/sources`, `/api/sync/status`, `/api/games`, `POST /api/sources/:key/test|pause|enable`, `POST /api/collect`, `POST /api/games`.
8. Proveer `/docs` y `/openapi.json` en Ruby. No considerar equivalentes los endpoints si falta documentación interactiva o esquema OpenAPI.
9. No reemplazar ni eliminar la implementación Python en esta rama durante la fase de caracterización. La versión Python sirve como oráculo de comparación.
10. TerraGazette debe seguir pudiendo consumir `GET /api/news/es` sin cambios de cliente.

## 10. Pruebas de caracterización pendientes

Crear pruebas Ruby para comparar la API Python y Ruby con fixtures equivalentes:

- [ ] Healthcheck y raíz/panel/docs.
- [ ] Listado, latest, trending, search y detalle de noticias.
- [ ] Filtros repetibles, categorías inválidas, plataformas lowercase, fechas y paginación.
- [ ] Editorial processed, es, queue y process (incluyendo Groq deshabilitado).
- [ ] Catálogo: filtros, franquicias, Steam search, alta manual/URL/nombre, unresolved, patch, resolve, delete, duplicados.
- [ ] Fuentes: listado, pause, enable, test exitoso, test bloqueado/error y fuente inexistente.
- [ ] Recolección: body omitido, fuentes seleccionadas, desconocidas, ejecución simultánea y modo serverless.
- [ ] Sync status, historial y detalle inexistente.
- [ ] Cron Bearer válido/inválido, secreto ausente, collect parcial/fallido/already_running, process y batch.
- [ ] Panel HTML operando contra Ruby sin cambios de contrato.
- [ ] Cliente TerraGazette operando contra Ruby sin cambios de contrato.

## 11. Observaciones y puntos que requieren inspección adicional

- Este inventario describe rutas, validaciones y schemas observables en routers/modelos. No sustituye la inspección de `repository.py`, `processed.py`, `queue.py`, `collector.py`, `config.py` ni de las migraciones para reproducir reglas de negocio y persistencia.
- Los detalles de error de validación de Pydantic/FastAPI pueden diferir de Sinatra; decidir si se replica el formato exacto de error además del status.
- CORS se configura solo cuando `CORS_ORIGINS` tiene valores; métodos permitidos: GET, POST, PATCH, DELETE; headers permitidos: `X-API-Key`, `Content-Type`. Verificar si el frontend/consumidores requieren CORS equivalente.
- El orden de routers es contractual: pipeline antes de news.
- FastAPI genera OpenAPI/Swagger automáticamente; Sinatra no lo hace por defecto.
- El modo serverless cambia la semántica de `POST /api/collect`: ejecución inline y HTTP 200, en lugar de background + 202.
- No se considera aquí resuelto el despliegue Ruby en Vercel. Primero implementar y probar localmente/branch aislada; el runtime de producción actual permanece Python.

---
**Fuente primaria:** `app/main.py`, `app/routers/*.py`, `app/deps.py`, `app/schemas.py`, `app/editorial/schemas.py`, `README.md` y pruebas `tests/test_api.py`, `tests/test_cron.py`.  
**Siguiente entregable:** matriz de caracterización de payloads y errores + diseño de persistencia/adaptadores Ruby.
