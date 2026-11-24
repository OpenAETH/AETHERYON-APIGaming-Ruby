# Proveedores: condiciones de uso, atribución y estado de verificación

> Este documento es un **checklist operativo**, no asesoría legal. Las condiciones deben confirmarse en cada sitio
> antes de producción. Lo marcado ⚠️ **no pudo verificarse** durante el desarrollo.

| Proveedor | Qué almacenamos | Atribución | Estado de verificación |
|---|---|---|---|
| IGN, PC Gamer, Eurogamer, GameSpot, Kotaku, Rock Paper Shotgun, Nintendo Life (RSS) | Título, enlace original, fecha, autor, categoría, imagen (URL, no el archivo) y extracto ≤500 caracteres | Siempre conservar `url`, fuente y fecha. Terra Gazette debe citar al medio | ⚠️ Revisar ToS/política de uso de feeds de cada medio (uso comercial, republicación, hotlinking de imágenes) |
| NewsMesh | Metadatos y extractos devueltos por la API | Según su documentación | ⚠️ Plan gratuito: 25 req/día, 10 artículos/req, 7 días de historial, 24 h de demora, **solo desarrollo y pruebas**. La API bloquea la fuente si `APP_ENV=production` y `NEWSMESH_PLAN!=commercial`. Endpoint, parámetros y autenticación por defecto **no verificados**: confirmar en https://newsmesh.co/docs |
| Steam Web API (`GetNewsForApp`) | Título, URL, fecha, autor, extracto ≤500 caracteres, etiquetas | Conservar `url` y nombre del juego | ⚠️ Revisar Steam Web API Terms of Use. Algunas noticias de Steam son de terceros (`is_external_url`): se tratan como metadatos + enlace, nunca como contenido propio |

## Reglas que el sistema aplica
- **No se guardan artículos completos**: `description` se trunca a 500 caracteres. El texto completo está solo en la `url` original.
- **Datos originales separados de los generados**: `original.*` (proveedor) vs. `categories/tags/platforms/classification` (reglas propias).
- **Credenciales solo por entorno**; nunca en endpoints, logs, errores ni claves de caché.
- **Terra Gazette** recibe registros con `status: pending_editorial_review`; no se auto-publica contenido externo.
- Las imágenes se guardan como **URL**; no se descargan ni se redistribuyen.

## Antes de producción
1. Confirmar licencias/ToS de los 7 medios y de Steam para el uso editorial previsto.
2. Contratar plan comercial de NewsMesh o deshabilitar la fuente.
3. Verificar manualmente los 7 feeds y los parámetros de NewsMesh con `POST /api/sources/{key}/test`.
