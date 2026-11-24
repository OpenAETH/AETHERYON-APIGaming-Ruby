# RUBY_PORT_CHARACTERIZATION.md
## AETHERYON Gaming API · Caracterización de comportamiento

Este documento transforma el inventario `RUBY_PORT_SPEC.md` en casos reproducibles para comparar la API Python de referencia con la futura implementación Ruby.

**Estado:** casos diseñados a partir de los routers, schemas y pruebas existentes. Se agregó una primera suite automatizada en `tests/test_characterization.py`. La suite fue escrita en la rama de migración, pero todavía no se ejecutó en el entorno del repositorio. Por lo tanto, los resultados esperados son contratos por validar, no resultados de ejecución.

## 1. Principios de comparación

1. La API Python de `main` es el oráculo de comportamiento.
2. La API Ruby se ejecutará en otro puerto/base de datos de prueba. Nunca apuntar pruebas destructivas a producción.
3. Comparar método, path, query, headers, status HTTP, content-type y JSON.
4. No comparar literalmente IDs autogenerados, timestamps, tiempos de ejecución, orden no contractual ni texto dinámico de proveedores. Normalizar esos campos y comparar su estructura/semántica.
5. Los tests que mutan estado deben correr sobre una base aislada y reiniciable.
6. Las pruebas de proveedores externos usan respuestas HTTP simuladas y fixtures deterministas, no feeds en vivo.
7. Credenciales de prueba se inyectan por entorno. Nunca guardar secretos reales en fixtures, logs o snapshots.

## 2. Matriz de escenarios HTTP

### A. Infraestructura y exposición

| ID | Request | Condición | Esperado | Evidencia |
|---|---|---|---|---|
| INF-01 | `GET /health` | DB disponible | 200, `{"status":"ok"}` | test_api.py |
| INF-02 | `GET /health` | DB no disponible | Error HTTP, no reportar healthy | Implementación ops.health; falta test explícito |
| INF-03 | `GET /` | — | Redirección a `/docs` | main.py |
| INF-04 | `GET /panel` | archivo estático presente | 200 HTML | test_api.py |
| INF-05 | `GET /docs` | — | 200 HTML Swagger UI | test_api.py |
| INF-06 | `GET /openapi.json` | — | 200 JSON OpenAPI | FastAPI; agregar aserción explícita |

### B. Noticias públicas

| ID | Request | Condición | Esperado | Evidencia |
|---|---|---|---|---|
| NEW-01 | `GET /api/news` | 2 artículos persistidos | 200 Page; `total=2` | test_api.py |
| NEW-02 | `GET /api/news?source=pcgamer` | fixture duplicado entre IGN/PC Gamer | 200; `total=1` y referencia del medio | test_api.py |
| NEW-03 | `GET /api/news?category=releases` | fixture clasificado | 200; total coincide con fixture | test_api.py |
| NEW-04 | `GET /api/news?category=nope` | categoría desconocida | 422 | test_api.py |
| NEW-05 | `GET /api/news?page_size=1` | 2 artículos | 200; `pages=2` | test_api.py |
| NEW-06 | `GET /api/news/latest` | 2 artículos recientes | 200; total 2 con ventana default 48h | test_api.py |
| NEW-07 | `GET /api/news/trending` | 2 artículos con cobertura distinta | 200 array; mayor score primero | test_api.py |
| NEW-08 | `GET /api/news/search?q=rtx` | título/extracto contiene RTX | 200; total 1 | test_api.py |
| NEW-09 | `GET /api/news/search?q=100%25` | literal no coincidente | 200; total 0 | test_api.py |
| NEW-10 | `GET /api/news/{id}` | ID existente | 200 Article con references | test_api.py |
| NEW-11 | `GET /api/news/zzz` | ID inexistente | 404 | test_api.py |
| NEW-12 | filtros repetidos `source=ign&source=pcgamer` | fixture con ambas fuentes | Debe aplicar colección de fuentes, no quedarse con una | Router; sumar test explícito |
| NEW-13 | filtros `platform` en mayúsculas | — | Normalización lowercase | Router; sumar test explícito |
| NEW-14 | `page=0`, `page_size=101`, `q` de 1 o 101 chars | — | 422 por límites de query | Declaraciones Query; sumar tests |

**Fixture editorial de noticia confirmado por tests:** artículo NVIDIA consolidado desde IGN y PC Gamer. Debe conservar dos referencias, categoría generada `hardware`, `original.categories=["News"]`, versión de clasificación y la imagen de IGN. El contrato separa el dato original de la clasificación generada.

### C. Pipeline editorial

| ID | Request | Condición | Esperado | Evidencia |
|---|---|---|---|---|
| EDT-01 | `GET /api/news/processed` | noticias completadas | 200 ProcessedPage; solo `completed` | Router/schema; fixture pendiente |
| EDT-02 | `GET /api/news/es` | noticias completadas | 200 SpanishPage; items aplanados en español y `pending` | Router/schema; fixture pendiente |
| EDT-03 | `GET /api/news/es?translated=true` | mezcla traducidas/no traducidas | solo translated=true | Router; sumar test |
| EDT-04 | `GET /api/news/queue` | cola con estados mixtos | 200 QueuePage con counts, usage_today y worker | Router/schema; fixture pendiente |
| EDT-05 | `GET /api/news/queue?status=invalid` | — | 422 por Literal | Router; sumar test |
| EDT-06 | `POST /api/news/{id}/process` | sin Admin | 401 si Admin key configurada | deps.py; sumar test |
| EDT-07 | `POST /api/news/{id}/process` | Groq deshabilitado | 503 | Router; sumar test |
| EDT-08 | `POST /api/news/{id}/process` | ID inexistente | 404 | Router; sumar test |
| EDT-09 | `POST /api/news/{id}/process?wait=false` | worker habilitado | 202 si pending/processing; 200 si completed/failed | Router; sumar test |
| EDT-10 | `POST /api/news/{id}/process?force=true&wait=true` | worker ejecutable | 200 con resultado final si el procesamiento concluye | Router; sumar test |
| EDT-11 | `GET /api/cron/process` | Groq deshabilitado + Cron válido | 200 `{"ok":true,"skipped":"groq_not_configured"}` | cron.py; sumar test |
| EDT-12 | `GET /api/cron/process?batch=21` | — | 422 | cron.py; sumar test |

### D. Catálogo de juegos

| ID | Request | Condición | Esperado | Evidencia |
|---|---|---|---|---|
| GAM-01 | `GET /api/games` | — | 200 array ordenado por name | Router |
| GAM-02 | `GET /api/games?status=active` | catálogo de test | solo active | test_api.py |
| GAM-03 | `GET /api/games?status=bad` | — | 422 | Router; sumar test |
| GAM-04 | `GET /api/games?franchise=elden%20ring` | franquicia registrada | comparación case-insensitive | test_api.py |
| GAM-05 | `GET /api/games?franchise=unassigned` | juegos sin franquicia | incluye null/vacío | Router; sumar test |
| GAM-06 | `GET /api/games/franchises` | una franquicia | `[{"name":"Elden Ring","count":1}]` | test_api.py |
| GAM-07 | `GET /api/games/steam-search?q=counter` | catálogo Steam simulado | resultados incluyen AppID 730 | test_api.py |
| GAM-08 | `GET /api/games/steam-search?q=x` | query corta | 422 | Router; sumar test |
| GAM-09 | `GET /api/games/steam-search?q=portal` | Steam no disponible | 503 y guía para AppID manual | test_api.py |
| GAM-10 | `GET /api/games/{id}` | ID inexistente | 404 `Juego no encontrado` | Router; sumar test |
| GAM-11 | `POST /api/games` | AppID extraído de URL Steam | 201, resolution=url, resolved=true | test_api.py |
| GAM-12 | `POST /api/games` | nombre exacto en catálogo Steam | resuelve AppID y resolution=catalog | test_api.py |
| GAM-13 | `POST /api/games` | nombre sin coincidencia | unresolved, appid=null, resolved=false | test_api.py |
| GAM-14 | `POST /api/games` | AppID duplicado | 409 | test_api.py |
| GAM-15 | `POST /api/games` | sin Admin | 401 cuando key configurada | deps.py; sumar test |
| GAM-16 | `PATCH /api/games/{id}` | unresolved + AppID manual | status active, resolution manual | test_api.py |
| GAM-17 | `PATCH /api/games/{id}` | AppID duplicado | 409 | Router; sumar test |
| GAM-18 | `POST /api/games/{id}/resolve` | ID inexistente | 404 | Router; sumar test |
| GAM-19 | `DELETE /api/games/{id}` | existente | 204 sin body | test_api.py |
| GAM-20 | `DELETE /api/games/{id}` | inexistente | 404 | Router; sumar test |

### E. Fuentes, recolección y sincronización

| ID | Request | Condición | Esperado | Evidencia |
|---|---|---|---|---|
| OPS-01 | `GET /api/sources` | catálogo base | 200; test espera 9 fuentes | test_api.py |
| OPS-02 | `GET /api/sources` | NewsMesh | objeto quota con daily_limit=25 en settings de test | test_api.py |
| OPS-03 | `POST /api/sources/{key}/pause` | Admin válido | 200, enabled=false | test_api.py |
| OPS-04 | `POST /api/sources/{key}/enable` | Admin válido | 200, enabled=true | Router; sumar test |
| OPS-05 | `POST /api/sources/{key}/test` | proveedor correcto | 200, ok=true y sample | test_api.py |
| OPS-06 | `POST /api/sources/{key}/test` | proveedor devuelve 503 | 200 JSON, ok=false, error incluye 503 | test_api.py |
| OPS-07 | `POST /api/sources/{key}/test` | fuente desconocida | 404 | test_api.py |
| OPS-08 | `POST /api/sources/{key}/test` | fuente bloqueada por configuración/licencia | 200 JSON, status=blocked | ops.py; sumar test |
| OPS-09 | `POST /api/collect` | sin Admin y key configurada | 401 | test_api.py |
| OPS-10 | `POST /api/collect` | Admin válido, fuentes seleccionadas | 202 y run_id/status/status_url | test_api.py |
| OPS-11 | `POST /api/collect` | fuente desconocida | 422 | ops.py; sumar test |
| OPS-12 | `POST /api/collect` | corrida ya activa | 409 | ops.py; test admite 409 o 202 por condición de carrera |
| OPS-13 | `POST /api/collect` | serverless=true | 200 inline con run y run_id igual a run.id | test_cron.py |
| OPS-14 | `GET /api/sync/status` | sin ejecuciones | 200; last_run=null | Router; sumar test |
| OPS-15 | `GET /api/sync/status` | después de corrida | running=false, total_articles y last_run | test_api.py |
| OPS-16 | `GET /api/sync/runs?limit=1` | historial disponible | array con última ejecución | Router; sumar test |
| OPS-17 | `GET /api/sync/runs/{id}` | ID inexistente | 404 | Router; sumar test |

**Comportamiento del collector respaldado por tests de pipeline:** una fuente con error no bloquea a las demás; el resultado puede ser `partial`. La corrida conserva logs por fuente. Una ejecución programada puede marcar fuentes como `skipped` cuando todavía no venció su intervalo mínimo. Las ejecuciones concurrentes se bloquean incluso entre instancias que comparten DB.

### F. Cron y autenticación

| ID | Request | Condición | Esperado | Evidencia |
|---|---|---|---|---|
| SEC-01 | POST admin endpoint sin header | Admin key configurada | 401 | test_api.py |
| SEC-02 | POST admin endpoint con key incorrecta | Admin key configurada | 401 | deps.py; sumar test |
| SEC-03 | POST admin endpoint sin key configurada en production | — | 503 | test_api.py |
| SEC-04 | GET cron sin Authorization | CRON_SECRET configurada | 401 | test_cron.py |
| SEC-05 | GET cron con Bearer incorrecto | CRON_SECRET configurada | 401 | test_cron.py |
| SEC-06 | GET cron con X-API-Key admin | CRON_SECRET configurada | 401 | test_cron.py |
| SEC-07 | GET cron con Bearer válido | CRON_SECRET ausente | 503 | test_cron.py |
| CRN-01 | `GET /api/cron/collect?source=ign` | Bearer válido, feed correcto | 200, ok=true, run.status=success | test_cron.py |
| CRN-02 | repetir cron collect sin force | intervalo vigente | 200; fuente skipped | test_cron.py |
| CRN-03 | `GET /api/cron/collect?source=zzz` | fuente desconocida | 422 | test_cron.py |
| CRN-04 | cron collect, todas las fuentes fallan | Bearer válido | 502, ok=false | test_cron.py |
| CRN-05 | cron collect mientras ya corre otra | — | 200, skipped=already_running | cron.py; sumar test |
| CRN-06 | `GET /api/cron/process` | worker apagado | 200, skipped=groq_not_configured | cron.py; sumar test |

## 3. Suite automatizada inicial

Archivo: `tests/test_characterization.py`.

Cubre de forma inicial:
- precedencia de rutas editoriales estáticas sobre `/api/news/{article_id}`;
- estructura vacía de `/api/news/es` y `/api/news/queue`;
- límites de query y categorías inválidas;
- separación entre autenticación Admin y Cron;
- ejecución inline de recolección en modo serverless y contrato del Article;
- validación básica del catálogo de juegos y del worker editorial deshabilitado.

La suite usa los fixtures de pytest existentes y una base PostgreSQL aislada por schema. La fixture `db` inicializa las migraciones antes de crear la app serverless. Los feeds externos están simulados con `httpx.MockTransport`.

**Ejecución local desde la raíz del repositorio:**
```powershell
$env:TEST_DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/aetheryon_test"
python -m pytest tests/test_characterization.py -q
```

Para ejecutar la batería Python existente completa:
```powershell
python -m pytest -q
```

La ejecución debe realizarse en un entorno de pruebas con PostgreSQL accesible. No usar la URL Neon de producción. Los tests aún no se han ejecutado desde este entorno de trabajo, así que el siguiente paso operativo es correrlos y corregir cualquier problema del arnés antes de capturar snapshots.

## 4. Contratos de payload que deben compararse

### Page de noticias
- Raíz: `items[]`, `page`, `page_size`, `total`, `pages`.
- Article: `id`, `title`, `description`, `source`, `url`, `canonical_url`, `published_at`, `captured_at`, `image_url`, `author`, `categories[]`, `tags[]`, `platforms[]`, `game`, `references[]`, `original`, `classification`, `score`.
- SourceRef: `key`, `name`; Reference: `source`, `source_name`, `url`, `published_at`, `captured_at`.
- Campos opcionales deben conservar nullability. No sustituir null por string vacío ni omitir arrays por null.

### Juego
La respuesta de juego es el registro persistido (incluye al menos `id`, `name`, `appid`, `url`, `platform`, `status`, `resolution`, `franchise`, `created_at`, `updated_at`). POST agrega `resolved` y `candidates`. El ID interno no es el AppID Steam.

### Sincronización
La respuesta de una corrida incluye `id`, `trigger`, `status`, tiempos y resultados por fuente. La estructura exacta debe fijarse con una captura de fixture de tests antes de snapshottear: no inferir campos adicionales por el README.

## 5. Normalización para comparación diferencial

Aplicar normalización únicamente a campos volátiles:
- Reemplazar IDs generados por marcadores estables según correspondencia entre respuestas.
- Convertir timestamps a UTC y comparar formato/semántica, no el instante exacto.
- Eliminar o normalizar latencias, duración y orden de logs no contractual.
- Ordenar arrays solo si el contrato no define orden. No reordenar `references` si su orden resulta relevante para el cliente.
- No normalizar status, mensajes de error contractuales, nombres de campos, nullability, tipos, categorías, referencias ni datos de negocio.
- No comparar muestras de proveedores vivos como fixtures deterministas.

## 6. Plan de ejecución

**Etapa 1 · Capturar referencia**
- Ejecutar primero `tests/test_characterization.py` y después la suite Python existente sobre commit de `main` en entorno de test.
- Crear DB efímera y configurar credenciales de test; los casos de esta suite activan el modo serverless para forzar la ejecución inline y desactivar workers/scheduler.
- Completar los escenarios pendientes identificados en las tablas.
- Exportar snapshots JSON saneados a `tests/characterization/python/`.

**Etapa 2 · Ruby**
- Implementar Sinatra en rama `ruby-port` usando los mismos fixtures y DB de test equivalente.
- Exportar snapshots a `tests/characterization/ruby/`.

**Etapa 3 · Diferencial**
- Comparar status, headers relevantes, estructura, tipos, valores y errores.
- Cada divergencia debe clasificarse: bug Ruby, diferencia accidental Python, comportamiento no determinista o decisión explícita de compatibilidad.
- No modificar el contrato de referencia para “hacer pasar” Ruby.

## 7. Criterio de aceptación

La equivalencia se considera aprobada cuando:
- todos los escenarios críticos tienen resultado capturado en Python;
- todos los escenarios equivalentes pasan en Ruby;
- las diferencias restantes están documentadas y aprobadas;
- el panel existente y el cliente TerraGazette consumen Ruby sin cambios de contrato;
- no se ha modificado ni desplegado sobre la versión productiva Python.

**Siguiente tarea concreta:** ejecutar la suite inicial en entorno PostgreSQL de test, ampliar escenarios faltantes y después implementar el comparador de snapshots.
