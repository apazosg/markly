# Markly

**Meeting recorder with AI transcription, speaker diarization, and smart summaries.**

Markly captures your meetings on Android or Windows, lets you add timestamped notes during the recording, and automatically generates a corrected transcript with speaker identification and a structured summary.

---

## Features

- **One-tap recording** with a foreground service that keeps capturing even when the screen is off (Android) or the app is in the background (Windows)
- **Timestamped notes** — pin a thought to the exact moment in the recording
- **AI transcription** — speech-to-text with speaker diarization in Spanish
- **Smart summaries** — structured markdown summaries adapted to meeting type (one-on-one, team meeting, etc.)
- **Speaker management** — rename speakers globally or reassign individual utterances
- **Session history** — search by title, label, or date; filter by speaker
- **Session merging** — long-press two sessions to concatenate them before transcription
- **Credit system** — transparent usage tracking (1 credit ≈ 1 minute of audio)
- **Auto-updates** — the app notifies you when a new version is available and installs it directly

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

## Building from source

### Prerequisites

- [Flutter 3.44+](https://docs.flutter.dev/get-started/install) with Android and/or Windows targets enabled
- Android: Android SDK, a device or emulator
- Windows: Visual Studio 2022 with "Desktop development with C++" workload

```bash
flutter pub get
flutter run -d android     # or: flutter run -d windows
flutter build apk --release
flutter build windows --release
```

---

## Windows audio capture (system audio / loopback)

By default, Windows records from the selected microphone. To capture system audio (Teams, Zoom, etc.):

1. Open **Sound → Recording** → enable **Stereo Mix** (if available on your sound card).
2. Or install [VB-Audio Cable](https://vb-audio.com/Cable/) (free): set it as the output device in your meeting app and select "CABLE Output" as the recording device in Markly.

---

## Privacy

See the full [Privacy Policy](https://adriangp.com/privacidad/markly.html).

---

## License

MIT — see [LICENSE](LICENSE).
