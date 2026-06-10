import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'models/note_entry.dart';
import '../../shared/csv_service.dart';
import '../../shared/file_service.dart';
import '../../shared/foreground_service.dart';
import '../../shared/wasapi_service.dart';

enum RecordingState { idle, recording, paused }

class RecordingController extends ChangeNotifier {
  // En Windows la captura va por el runner nativo (WasapiService); en el resto
  // de plataformas por el paquete `record`.
  final _recorder = AudioRecorder();

  RecordingState _state = RecordingState.idle;
  Duration _elapsed = Duration.zero;
  List<NoteEntry> _notes = [];
  // Audio del sistema (la reunión) capturado vía WASAPI loopback nativo y
  // mezclado con el micro en la misma pista. Por defecto activado. Solo Windows.
  bool _captureSystemAudio = true;
  bool _wasapiActive = false;
  double _amplitude = -60.0; // dBFS, plataformas no-Windows
  double _winLevel = 0.0; // 0–1, Windows (nativo)
  int? _pendingTimestampMs;
  String? _audioPath;
  String? _notesPath;
  Timer? _timer;
  StreamSubscription<Amplitude>? _ampSub;

  RecordingState get state => _state;
  Duration get elapsed => _elapsed;
  List<NoteEntry> get notes => List.unmodifiable(_notes);
  bool get captureSystemAudio => _captureSystemAudio;
  bool get systemAudioSupported => WasapiService.isSupported;
  bool get canAddNote => _state != RecordingState.idle;
  bool get hasPendingTimestamp => _pendingTimestampMs != null;
  int? get pendingTimestampMs => _pendingTimestampMs;

  // Nivel 0–1 para el medidor. En Windows lo da el nativo; en el resto se deriva
  // del dBFS (silencio ≈ -60 dBFS).
  double get amplitudeLevel {
    if (_state != RecordingState.recording) return 0.0;
    if (Platform.isWindows) return _winLevel.clamp(0.0, 1.0);
    return ((_amplitude + 60) / 60).clamp(0.0, 1.0);
  }

  void setCaptureSystemAudio(bool value) {
    _captureSystemAudio = value;
    notifyListeners();
  }

  // null = éxito, String = mensaje de error para mostrar al usuario
  Future<String?> startRecording() async {
    if (_state != RecordingState.idle) return null;

    // En Windows el modelo de permisos no usa hasPermission(). En Android sí.
    if (!Platform.isWindows && !await _recorder.hasPermission()) {
      return 'Permiso de micrófono denegado';
    }

    final paths = await FileService.createSessionPaths();
    _audioPath = paths.audioPath;
    _notesPath = paths.notesPath;
    _notes = [];
    _elapsed = Duration.zero;
    _amplitude = -60.0;
    _winLevel = 0.0;

    try {
      if (Platform.isWindows) {
        final ok = await WasapiService.start(_audioPath!, captureSystem: _captureSystemAudio);
        if (!ok) return 'No se pudo iniciar la captura de audio';
        _wasapiActive = true;
      } else {
        await _recorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1),
          path: _audioPath!,
        );
        _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amp) {
          _amplitude = amp.current;
        });
      }
    } catch (e) {
      return 'Error al iniciar grabación: $e';
    }

    await WakelockPlus.enable();
    await ForegroundService.start('Grabando…');

    _state = RecordingState.recording;
    _startTimer();
    notifyListeners();
    return null;
  }

  Future<void> pauseRecording() async {
    if (_state != RecordingState.recording) return;
    if (Platform.isWindows) {
      await WasapiService.pause();
    } else {
      await _recorder.pause();
    }
    _timer?.cancel();
    _state = RecordingState.paused;
    await ForegroundService.update('En pausa · ${_formatElapsed(_elapsed)}');
    notifyListeners();
  }

  Future<void> resumeRecording() async {
    if (_state != RecordingState.paused) return;
    if (Platform.isWindows) {
      await WasapiService.resume();
    } else {
      await _recorder.resume();
    }
    _startTimer();
    _state = RecordingState.recording;
    notifyListeners();
  }

  Future<({String audioPath, String notesPath, int durationMs})?> stopRecording() async {
    if (_state == RecordingState.idle) return null;
    _timer?.cancel();
    await _ampSub?.cancel();
    if (Platform.isWindows) {
      if (_wasapiActive) {
        await WasapiService.stop();
        _wasapiActive = false;
      }
    } else {
      await _recorder.stop();
    }
    await WakelockPlus.disable();
    await ForegroundService.stop();

    if (_notesPath != null) await CsvService.write(_notesPath!, _notes);

    final result = (audioPath: _audioPath!, notesPath: _notesPath!, durationMs: _elapsed.inMilliseconds);

    _state = RecordingState.idle;
    _elapsed = Duration.zero;
    _notes = [];
    _amplitude = -60.0;
    _winLevel = 0.0;
    _pendingTimestampMs = null;
    notifyListeners();

    return result;
  }

  // Pins the current timestamp. Call this when the user taps "Añadir nota".
  void pinTimestamp() {
    if (!canAddNote) return;
    _pendingTimestampMs = _elapsed.inMilliseconds;
    notifyListeners();
  }

  void cancelPin() {
    _pendingTimestampMs = null;
    notifyListeners();
  }

  // Commits the note using the previously pinned timestamp.
  void addNote(String text) {
    if (text.trim().isEmpty) return;
    _notes = [..._notes, NoteEntry(
      timestampMs: _pendingTimestampMs ?? _elapsed.inMilliseconds,
      text: text.trim(),
    )];
    _pendingTimestampMs = null;
    notifyListeners();
  }

  void updateNoteTitle(int index, String title) {
    if (index < 0 || index >= _notes.length) return;
    final note = _notes[index];
    final updated = NoteEntry(
      timestampMs: note.timestampMs,
      text: note.text,
      title: title.trim().isEmpty ? null : title.trim(),
    );
    _notes = List.from(_notes)..[index] = updated;
    notifyListeners();
  }

  void removeNote(int index) {
    if (index < 0 || index >= _notes.length) return;
    _notes = List.from(_notes)..removeAt(index);
    notifyListeners();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _elapsed += const Duration(milliseconds: 100);
      if (Platform.isWindows && _state == RecordingState.recording) {
        WasapiService.amplitude().then((v) {
          _winLevel = v;
        }).catchError((_) {});
      }
      // Update notification once per second
      if (_elapsed.inMilliseconds % 1000 < 100) {
        ForegroundService.update(_formatElapsed(_elapsed));
      }
      notifyListeners();
    });
  }

  static String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? 'Grabando · $h:$m:$s' : 'Grabando · $m:$s';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
