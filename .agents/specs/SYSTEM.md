---
id: SYSTEM
description: "Arquitectura, stack, NFRs globales y cross-cutting concerns de la app Markly (recorder): grabadora Flutter Android+Windows cliente de markly-backend"
state: ready
---

# SYSTEM SPECIFICATION — Markly (recorder)

> Specs reverse-engineered del código (2026-06-19). Lo no confirmado va marcado `[INFERRED]`.
> El comportamiento del servidor está specado aparte en `markly-backend/.agents/specs/`; aquí solo el cliente.

## Architecture Constraints

- **App Flutter multiplataforma (Android + Windows).** UI Material (tema oscuro, shell con `NavigationBar`); estado por `ChangeNotifier` (`RecordingController`).
- **Cliente de `markly-backend`** (`markly.adriangp.com`) vía `ApiService` (HTTP). No procesa transcripción/resumen localmente; los delega al backend.
- **Captura de audio divergente por plataforma:**
  - Android: paquete `record` → AAC-LC 16 kHz mono 32 kbps (`audio.m4a`).
  - Windows: componente nativo WASAPI en el runner (`windows/runner/wasapi_recorder.*`) que mezcla micro + audio del sistema (loopback) en una sola pista `audio.wav`. Sin software externo.
- **Persistencia local por sesión:** `Documents/Recorder/sessions/YYYYMMDD_HHmmss/` con `audio.(m4a|wav)`, `notes.csv` (`timestamp_ms,timestamp_hms,note`) y `metadata.json`.
- **Auth Firebase (JWT)** enviado en cada llamada al backend.

## Technology Stack

| Capa | Tecnología |
|---|---|
| Framework | Flutter 3.44+ / Dart 3.12+ |
| Audio Android | `record ^5.2` (AAC 16 kHz mono) |
| Audio Windows | WASAPI nativo (runner C++), MethodChannel `com.adriangp.markly/wasapi` |
| Auth | `firebase_auth` (JWT) |
| Notificaciones | `flutter_local_notifications` (Android) / SnackBar in-app (Windows) |
| Otros | `path_provider`, `intl`, `wakelock_plus`, `shared_preferences` |
| Plataformas | Android (`minSdk 23`) · Windows |

## Global Non-Functional Requirements

### SYS-NFR-001 — Audio apto para diarización
THE SYSTEM SHALL grabar en Android a 16 kHz mono (32 kbps AAC) para que la transcripción/diarización funcione y las reuniones largas quepan bajo el tope de subida (~7 h en 100 MB).

### SYS-NFR-002 — Grabación resiliente en segundo plano
WHILE una grabación está activa, THE SYSTEM SHALL mantener el wakelock y, en Android, un foreground service con notificación de tiempo transcurrido, para no perder la captura al apagarse la pantalla o pasar a background.

### SYS-NFR-003 — Captura unificada en Windows sin software externo
WHEN se graba en Windows con "incluir audio del sistema", THE SYSTEM SHALL capturar micro + salida por defecto (loopback) y escribir una única pista mezclada, sin requerir Stereo Mix ni cables virtuales.

### SYS-NFR-004 — Autenticación
THE SYSTEM SHALL incluir el JWT de Firebase en toda llamada al backend; sin sesión válida, SHALL llevar al login.

## Cross-Cutting Concerns

- **Foreground service (Android):** vía MethodChannel a un servicio nativo Kotlin; muestra el cronómetro.
- **Cuenta y créditos:** `account_page` consulta el consumo/créditos del backend (`/usage/summary`).
- **Auto-actualización (Windows):** `update_service` comprueba/instala nuevas versiones.
- **Recordatorios de tareas:** `reminder_service` evalúa vencimientos al arrancar/por timer/tras editar (catch-up), sin alarmas de SO.

## Assumptions
- `[ASSUMPTION]` El flujo de subida envía siempre `audio` + `notes.csv` a `POST /sessions` del backend.

## Open Questions
- `[PENDING]` Falso positivo de Windows Defender (`Wacatac!ml`) sobre el `.exe` sin firmar, atribuido al loopback WASAPI (v0.1.2). Plan: firma con Azure Trusted Signing (ver memoria/planning).
- `[PENDING]` El loopback sigue la salida por defecto; cambiarla a mitad de grabación no se reengancha. Mejora futura: WAV estéreo (L=micro, R=sistema) + Deepgram `multichannel`.
