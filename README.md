# Markly

**Meeting recorder with AI transcription, speaker diarization, and smart summaries.**

Markly captures your meetings on Android or Windows, lets you add timestamped notes during the recording, and automatically generates a corrected transcript with speaker identification and a structured summary — adapted to the meeting type and length.

---

## Features

- **One-tap recording** with a foreground service that keeps capturing even when the screen is off (Android) or the app is in the background (Windows)
- **Timestamped notes** — tap to pin a thought to the exact moment in the recording
- **AI transcription** — Deepgram Whisper Large with speaker diarization in Spanish
- **Smart summaries** — Gemini 2.5 Flash generates structured markdown summaries, adapted to meeting type (one-on-one, team meeting, etc.)
- **Speaker management** — rename speakers globally or reassign individual utterances
- **Session history** — search by title, label, or date (e.g. "junio"), filter by speaker
- **Session merging** — long-press two sessions to concatenate them before transcription
- **Credit system** — transparent usage tracking (1 credit ≈ 1 minute of audio)
- **Auto-updates** — the app notifies you when a new version is available and installs it directly (Windows via App Installer, Android via browser)

---

## Platforms

| Platform | Audio source | Min version |
|---|---|---|
| Android | Microphone (`RECORD_AUDIO`) | Android 6.0 (API 23) |
| Windows | WASAPI device selector | Windows 10 |

---

## Download

Get the latest release from the [Releases](https://github.com/apazosg/markly/releases) page:

- **Android**: `markly-android-vX.X.X.apk` — sideload (enable "Install unknown apps" for your browser)
- **Windows**: `markly-windows-vX.X.X.msix` — double-click to install via Windows App Installer

> **Note (Windows):** The MSIX is self-signed. On first install Windows will ask you to trust the publisher. This is a one-time step per machine.

---

## Architecture

```
┌─────────────────────────────────────┐
│  Flutter app (Android + Windows)    │
│  Firebase Auth · HTTP (http pkg)    │
└──────────────┬──────────────────────┘
               │ HTTPS
┌──────────────▼──────────────────────┐
│  Backend — markly.adriangp.com      │
│  FastAPI · SQLAlchemy · PostgreSQL  │
│  Cloudflare Tunnel                  │
└──────┬───────────────────┬──────────┘
       │                   │
┌──────▼──────┐   ┌────────▼────────┐
│  Deepgram   │   │  Google Gemini  │
│  Whisper L  │   │  2.5 Flash      │
│  (audio →   │   │  (transcript →  │
│  transcript)│   │  summary/title) │
└─────────────┘   └─────────────────┘
```

### Processing pipeline

```
Upload (.m4a + notes .csv)
  └─ Deepgram Whisper Large
        ├─ raw transcript
        ├─ speaker diarization (utterances per speaker)
        └─ word-level timestamps
  └─ Gemini 2.5 Flash
        ├─ corrected transcript (proper nouns, technical terms)
        ├─ structured summary (markdown bullets)
        ├─ title (4–6 words)
        ├─ labels (reuses existing + suggests new, 1–4)
        └─ topics []
```

---

## Building from source

### Prerequisites

- [Flutter 3.44+](https://docs.flutter.dev/get-started/install) with Android and/or Windows targets enabled
- Android: Android SDK, a device or emulator
- Windows: Visual Studio 2022 with "Desktop development with C++" workload

### App

```bash
flutter pub get
flutter run -d android     # or: flutter run -d windows
flutter build apk --release
flutter build windows --release
```

### Backend (self-hosting)

The backend requires Docker Compose and the following environment variables in `backend/.env`:

```env
DB_PASSWORD=your_postgres_password
FIREBASE_SA_JSON={"type":"service_account",...}   # Firebase service account JSON
DEEPGRAM_API_KEY=your_deepgram_key
GEMINI_API_KEY=your_gemini_key
CLOUDFLARE_TUNNEL_TOKEN=your_tunnel_token         # optional, remove service if not used
UNLIMITED_EMAILS=admin@example.com                # comma-separated, no credit limit
```

```bash
cd backend
docker compose up -d
```

The API will be available at `http://localhost:8000`. Point the Flutter app to it with:

```bash
flutter run --dart-define=API_BASE_URL=http://localhost:8000
```

#### Firebase setup

1. Create a Firebase project and enable **Google Sign-In** under Authentication.
2. Download the service account JSON and set it as `FIREBASE_SA_JSON`.
3. Add the Android app (`com.adriangp.markly`) and download `google-services.json` into `android/app/`.
4. For Windows, add a web app and configure the OAuth client ID in `windows/runner/main.cpp` (or via `--dart-define=GOOGLE_DESKTOP_CLIENT_SECRET`).

---

## Windows audio capture (system audio / loopback)

By default, Windows records from the selected microphone. To capture system audio (Teams, Zoom, etc.):

1. Open **Sound → Recording** → enable **Stereo Mix** (if available on your sound card).
2. Or install [VB-Audio Cable](https://vb-audio.com/Cable/) (free): set it as the output device in your meeting app and select "CABLE Output" as the recording device in Markly.

---

## Privacy

Audio and transcripts are processed by [Deepgram](https://deepgram.com/privacy) and [Google Gemini](https://policies.google.com/privacy). The developer does not manually access your recordings or transcripts. See the full [Privacy Policy](https://adriangp.com/privacidad/markly.html).

---

## License

MIT — see [LICENSE](LICENSE).
