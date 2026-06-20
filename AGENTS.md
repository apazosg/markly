# recorder — Grabadora de reuniones con notas en timestamp

## Qué es

App Flutter (Android + Windows) para grabar reuniones y añadir notas fijadas al timestamp de la grabación. Salida: archivo de audio `.m4a` + `.csv` con las notas.

## Spec Index (`.agents/specs/`)

Reverse-engineered del código (solo el cliente; el backend está en `markly-backend/.agents/specs/`), `state: draft`.

| ID | Descripción |
|---|---|
| `SYSTEM` | Arquitectura, stack, NFRs globales, cross-cutting |
| `US-001` | Autenticación y cuenta (Firebase) |
| `US-002` | Grabación con notas en timestamp |
| `US-003` | Captura de audio multiplataforma (Android mic / Windows WASAPI) |
| `US-004` | Subida e historial |
| `US-005` | Asistente de chat y tareas |
| `US-006` | Recordatorios de tareas |

## Stack

### App (Flutter)
- Flutter 3.44+ / Dart 3.12+
- `record ^5.2` — captura de audio multiplataforma
- `path_provider ^2.1` — rutas de almacenamiento
- `intl ^0.19` — formateo de fechas
- `firebase_auth` — autenticación (Firebase JWT)

### Backend (repo separado: `/workspace/markly-backend/`, `apazosg/markly-backend`)
> El backend **no** está en `recorder/backend/`. Vive en el repo separado `markly-backend/`. El upload está en `markly-backend/sessions.py`.
- FastAPI + SQLAlchemy async + PostgreSQL
- Deepgram Whisper Large — transcripción + diarización en español
- Gemini 2.5 Flash (`google-genai`) — post-proceso: corrección de transcript, resumen, título, etiquetas, tópicos
- Firebase Admin SDK — verificación de tokens JWT
- Desplegado en `markly.adriangp.com`

> El comportamiento del backend es fuente de verdad en `markly-backend/.agents/specs/`. (El antiguo `docs/backend-plan.md` con el plan inicial Firebase/Firestore se eliminó por desactualizado el 2026-06-19.)

## Comandos

```bash
flutter pub get          # instalar dependencias
flutter analyze          # typecheck + lint
flutter run -d android   # Android (requiere dispositivo/emulador)
flutter run -d windows   # Windows (solo desde Windows con SDK instalado)
flutter build apk        # build Android
flutter build windows    # build Windows
```

## Arquitectura

```
lib/
  main.dart                          # entry point
  app.dart                           # MaterialApp + NavigationBar shell
  shared/
    theme.dart                       # dark theme con accent rojo
    csv_service.dart                 # lectura/escritura CSV de notas
    file_service.dart                # paths de sesión (Documents/Recorder/sessions/YYYYMMDD_HHmmss/)
    metadata_service.dart            # lectura/escritura metadata.json por sesión
    api_service.dart                 # cliente HTTP hacia markly.adriangp.com
    foreground_service.dart          # MethodChannel al foreground service nativo (Android)
  features/
    auth/
      auth_service.dart
      login_page.dart
    recording/
      models/note_entry.dart         # {timestampMs, text, title?}
      recording_controller.dart      # ChangeNotifier: estado de grabación y lista de notas
      recording_page.dart            # UI: timer, notas, controles, input
    history/
      history_page.dart              # lista de sesiones (local + remota), búsqueda clásica, etiquetas
      transcript_page.dart           # transcript diarizado + resumen
    chat/
      chat_page.dart                 # asistente RAG: pregunta por texto o voz; chips de tareas detectadas
    tasks/
      tasks_page.dart                # tareas: Sugerencias (confirmar/descartar) · Pendientes · Hechas

(backend en repo separado: /workspace/markly-backend/)
  main.py                            # FastAPI app
  auth.py                            # verificación Firebase JWT
  config.py                          # Settings (pydantic-settings)
  database.py                        # SQLAlchemy async + migraciones inline
  models.py                          # ORM: Session (col. embedding), Task/TaskStatus, TranscriptStatus
  sessions.py                        # router /sessions (CRUD, upload, reprocess, mezcla micro+sistema)
  transcription.py                   # pipeline: Deepgram → Gemini 2.5 Flash (fallback a flash-lite)
  gemini.py                          # cliente google-genai compartido
  embeddings.py                      # gemini-embedding-001: documento por reunión, coseno en Python
  chat.py                            # router /chat y /chat/audio: recuperación por similitud + RAG
  tasks.py                           # router /tasks + extracción automática desde reuniones
  merge.py · usage.py                # merge de sesiones · créditos
  Dockerfile / docker-compose.yml
```

### Tareas / recordatorios (detección + confirmación)

Las reuniones y el chat generan tareas accionables; el usuario las confirma antes de que entren en Pendientes:

- **Detección automática**: el post-proceso de Gemini de cada reunión devuelve también `tasks`
  (mismo JSON, sin llamada extra) → se guardan como `Task` con estado `suggested` vinculadas a la reunión.
  El chat (`/chat`) devuelve `suggested_tasks` junto a la respuesta.
- **Confirmación**: las sugeridas aparecen con check ✓ / descartar ✗ en la pestaña Tareas; en el chat,
  como chips con botón "Añadir". Solo al confirmar pasan a `pending`.
- **Reproceso**: regenerar una reunión reemplaza sus sugeridas sin tocar las ya confirmadas/hechas.
- **Modelo** `tasks`: text, status (suggested|pending|done), source_type (meeting|chat|manual),
  source_session_id, assignee, due_date, priority. Tabla nueva creada por `create_all`.
- **Endpoints**: `GET/POST/PATCH/DELETE /tasks`.

### Búsqueda semántica y asistente (RAG)

Además de la búsqueda clásica del historial (título/etiquetas/fecha, en cliente), hay un
asistente conversacional sobre las reuniones:

- **Indexación**: al terminar transcripción/reproceso se genera un embedding por reunión
  (`gemini-embedding-001`, 768 dim) a partir de título + resumen + temas + etiquetas + notas.
  Se guarda como JSON en `sessions.embedding`. Reuniones antiguas se reindexan al vuelo en el primer `/chat`.
- **Recuperación**: coseno en Python sobre los embeddings del usuario (escala personal; sin pgvector).
  Top-6 reuniones → contexto para Gemini 2.5 Flash, que responde en español citando reuniones.
- **Entradas**: `POST /chat` (texto) y `POST /chat/audio` (voz → Deepgram transcribe la pregunta → RAG).
- **Créditos**: guard `assert_credits_available` antes de procesar; se registra Deepgram (voz) y Gemini (respuesta).

### Pipeline de procesamiento

```
Upload (audio .m4a + notes .csv)
  └─ Deepgram Whisper Large
        ├─ transcript raw
        ├─ diarization (utterances por hablante)
        └─ word-level timestamps
  └─ Gemini 2.5 Flash (post-proceso)
        ├─ transcript corregido (nombres propios, términos técnicos)
        ├─ summary (estructura adaptada a duración y etiqueta "one to one")
        ├─ title (4–6 palabras)
        ├─ labels (reutiliza existentes + sugiere nuevas, 1–4)
        └─ topics []
```

## Formato de salida

Cada sesión crea una carpeta en `Documents/Recorder/sessions/YYYYMMDD_HHmmss/`:
- `audio.m4a` (Android) / `audio.wav` (Windows) — en Windows ya incluye micro + audio del sistema mezclados
- `notes.csv` — `timestamp_ms,timestamp_hms,note`

## Captura de audio en Windows (WASAPI unificado: micro + sistema)

En Windows la grabación **no usa el paquete `record`**: la hace un componente nativo WASAPI en el runner que captura micro + audio del sistema y escribe **una sola pista mezclada** `audio.wav`. **Sin software externo** (ni Stereo Mix ni cables). En la UI es un interruptor "Incluir audio del sistema" (por defecto ON); sin selección de dispositivo (usa los endpoints por defecto).

- **Micro**: endpoint de captura por defecto (WASAPI).
- **Sistema**: endpoint de salida por defecto vía loopback (`AUDCLNT_STREAMFLAGS_LOOPBACK`).
- Ambas fuentes se inicializan con `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` → el motor de Windows las entrega ya en **48 kHz / 16-bit / mono**, así que el nativo solo **suma con saturación** (sin resampler propio).
- El hilo del micro es el **reloj maestro**: por cada muestra de micro mezcla la de sistema disponible (buffer compartido) o silencio. Una sola pista, sin deriva entre relojes, sin mezcla en backend.
- El upload sube un único `audio.wav` (flujo idéntico a Android, que sube `audio.m4a`).

### Código del componente WASAPI
- `windows/runner/wasapi_recorder.{h,cpp}` — captura micro + loopback, mezcla y escribe `audio.wav`. Expone `Amplitude()` (pico 0–1) para el VU.
- `windows/runner/flutter_window.{h,cpp}` — MethodChannel `com.adriangp.markly/wasapi` (`start{path,captureSystem}`/`stop`/`pause`/`resume`/`amplitude`).
- `windows/runner/CMakeLists.txt` — añade `wasapi_recorder.cpp` y enlaza `ole32.lib`.
- `lib/shared/wasapi_service.dart` — wrapper Dart del canal. En `RecordingController`, Windows usa este servicio en vez de `record`.

> En Windows no hay selector de micro (usa el de por defecto) ni medidor por dBFS de `record`: el nivel viene de `Amplitude()` por polling. El loopback sigue la salida por defecto (si se cambia a mitad de grabación, no se reengancha). Mejora futura: enviar WAV estéreo multicanal (L=micro, R=sistema) con Deepgram `multichannel=true` para diarización perfecta.

## Plataformas

| Plataforma | Audio | Notas |
|---|---|---|
| Android | Micrófono ambiente (`RECORD_AUDIO` permission) | `minSdk = 23` |
| Windows | Micro + audio del sistema en una pista (WASAPI nativo unificado) | Requiere Windows SDK en build |

## Base de datos (PostgreSQL)

Tabla `sessions`: columnas JSON (`labels`, `utterances_data`, `paragraphs_data`, `notes_content`, etc.) guardadas como `TEXT` serializado, no `JSONB`. Relevante para cualquier trabajo de FTS o índices — ver `.agents/planning/search-pagination-ideas.md`.
