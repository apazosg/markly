---
id: search-pagination-ideas
state: draft
date: 2026-06-19
---

# Markly — Ideas: búsqueda, paginación y filtros vectoriales

> Reubicado a `.agents/planning/` el 2026-06-19. Ideas/futuro, no implementado.

Estado actual (2026-06-09): búsqueda client-side sobre sesiones ya cargadas en memoria.
Funciona bien hasta ~50–100 sesiones. Este doc recoge lo que habría que construir cuando
la escala lo exija, sin orden de prioridad definitivo.

---

## 1. Paginación

**Problema:** `GET /sessions` devuelve todas las sesiones del usuario. Con cientos de entradas
esto es lento en red y en renderizado.

**Solución recomendada: cursor basado en `(created_at DESC, id)`**

```
GET /sessions?limit=20&before=<opaque_cursor>
→ { items: [...], next_cursor: "...", total: null }
```

- Sin `offset`: es inestable cuando se insertan sesiones nuevas mientras el usuario pagina.
- El cursor codifica `(created_at, id)` en base64; el backend hace `WHERE (created_at, id) < (ts, id)`.
- El cliente carga más al hacer scroll hasta el fondo (infinite scroll).
- La pantalla de historial actual ordena por `localId` (YYYYMMDD_HHmmss) — compatible,
  basta con usar `created_at` que ya existe en el modelo.

**Pre-requisito:** añadir índice `(uid, created_at DESC, id DESC)` en la tabla `sessions`.

---

## 2. Búsqueda en backend

**Problema:** la búsqueda client-side solo opera sobre títulos, etiquetas y notas.
El transcript completo (Deepgram, `utterances_data`/`paragraphs_data`) es mucho más rico
y nunca baja al cliente de forma indexable.

### 2a. FTS con PostgreSQL `tsvector`

Añadir una columna generada `search_vector tsvector` que indexe:

| Campo | Peso |
|---|---|
| `title` | A |
| `labels` (cada elemento) | B |
| `summary` | B |
| Texto plano extraído de `utterances_data` | C |
| `notes_content` (cada `text`) | C |

```sql
-- Columna generada (requiere extraer texto de JSON antes, o hacerlo en trigger)
ALTER TABLE sessions ADD COLUMN search_vector tsvector;
CREATE INDEX idx_sessions_search ON sessions USING GIN(search_vector);
```

Como los campos JSON están en TEXT y no JSONB, la opción más limpia es un trigger
`BEFORE INSERT OR UPDATE` que construya el vector concatenando los textos extraídos.

**Endpoint:**
```
GET /sessions/search?q=presupuesto+Q3&limit=20&before=<cursor>
→ { items: [{ ...session, rank: 0.87, snippet: "...presupuesto del <b>Q3</b>..." }], next_cursor }
```

El `rank` se calcula con `ts_rank_cd`. El `snippet` con `ts_headline`.

**Cliente:** cuando `_query` no está vacío, sustituir `listSessions()` por `searchSessions(q)`
con debounce ~300 ms. Las sesiones locales no subidas se filtran client-side y se mezclan
al principio (tienen score = 0.5 fijo para no competir con los resultados del backend).

### 2b. Filtros estructurados (sin FTS)

Se pueden añadir como query params ortogonales al texto libre:

| Parámetro | Semántica |
|---|---|
| `label=sprint,presupuesto` | Sesiones que tienen TODOS los labels indicados |
| `after=2026-01-01` / `before=2026-06-01` | Rango de fechas |
| `min_duration_s=600` | Duración mínima |
| `status=done` | Solo sesiones con transcript procesado |

En PostgreSQL los labels son TEXT (JSON array serializado). Para hacer el filtro eficiente
habría que migrar la columna a `TEXT[]` o `JSONB` y añadir un índice GIN:

```sql
ALTER TABLE sessions ALTER COLUMN labels TYPE JSONB USING labels::jsonb;
CREATE INDEX idx_sessions_labels ON sessions USING GIN(labels);
-- Consulta: WHERE labels @> '["sprint"]'::jsonb
```

---

## 3. Búsqueda vectorial (semántica)

**Caso de uso:** el usuario busca "reunión donde hablamos de las vacaciones de verano"
sin recordar ninguna palabra exacta del título o etiquetas.

**Stack:** `pgvector` + modelo de embeddings ligero (e.g. `text-embedding-3-small` de OpenAI,
o un modelo local vía Ollama para evitar costes).

**Flujo:**
1. Al terminar la transcripción, generar embedding del `summary` (256–512 tokens).
2. Guardar en columna `embedding vector(1536)` (o la dimensión del modelo elegido).
3. Añadir índice HNSW: `CREATE INDEX ON sessions USING hnsw(embedding vector_cosine_ops)`.
4. En búsqueda: embeber el query del usuario, buscar los K vecinos más cercanos.

```sql
SELECT id, title, 1 - (embedding <=> $query_vec) AS similarity
FROM sessions
WHERE uid = $uid
ORDER BY embedding <=> $query_vec
LIMIT 20;
```

**Combinación con FTS (hybrid search):** Reciprocal Rank Fusion (RRF) mezcla los rankings
de FTS y vectorial sin necesidad de normalizar las puntuaciones:

```
score_rrf = 1/(k + rank_fts) + 1/(k + rank_vector)   # k=60 typical
```

Esto es lo que hacen Supabase, Neon y PGVector natively. Implementable en Python sin deps extra.

**Pre-requisito:** instalar extensión `pgvector` en el Postgres de producción.
En Docker Compose añadir `ankane/pgvector` como imagen base o usar `pgvector/pgvector:pg16`.

---

## 4. Resumen de pre-requisitos por fase

| Mejora | Pre-requisito técnico |
|---|---|
| Paginación | Índice `(uid, created_at DESC, id DESC)` |
| Filtro por label | Migrar `labels` TEXT → JSONB + índice GIN |
| FTS PostgreSQL | Columna `search_vector` + trigger + índice GIN |
| Búsqueda vectorial | `pgvector` instalado + columna `embedding` + índice HNSW |
| Hybrid search | FTS + vectorial ambos implementados |

La migración de TEXT → JSONB para las columnas JSON es el paso que más impacto tiene
en el resto: desbloquea filtros, mejora la construcción del tsvector, y simplifica el
código Python (ya no hace falta `json.loads` manual en queries).

---

## 5. Notas de diseño cliente

- La búsqueda local actual (history_page.dart `_scoreSession`) puede mantenerse como
  fallback para sesiones no subidas.
- Con paginación, el historial deja de cargar todo en `initState` y pasa a lazy load.
  El estado `_sessions` pasa a ser una lista acumulativa; `_load()` se convierte en
  `_loadNextPage()` con un `ScrollController`.
- El buscador actual desaparece mientras el usuario escribe si `_query` no está vacío
  y se sustituye por los resultados del backend. Añadir un indicador de "buscando…"
  para el latency gap del debounce.
