import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../features/recording/models/note_entry.dart';
import 'file_service.dart';

class SessionMetadata {
  String? title;
  List<String> labels;
  Map<String, String> speakerNames;
  // Inferidos por la IA (solo lectura del servidor). Se muestran con ⭐ cuando el
  // id no está confirmado en speakerNames; el nombre manual tiene prioridad.
  Map<String, String> speakerNamesAuto;
  List<NoteEntry> transcriptNotes;
  Map<String, String> utteranceEdits;
  Map<String, String> speakerOverrides;
  String generalNotes;
  int? durationMs;

  SessionMetadata({
    this.title,
    this.durationMs,
    List<String>? labels,
    Map<String, String>? speakerNames,
    Map<String, String>? speakerNamesAuto,
    List<NoteEntry>? transcriptNotes,
    Map<String, String>? utteranceEdits,
    Map<String, String>? speakerOverrides,
    String? generalNotes,
  })  : labels = labels ?? [],
        speakerNames = speakerNames ?? {},
        speakerNamesAuto = speakerNamesAuto ?? {},
        transcriptNotes = transcriptNotes ?? [],
        utteranceEdits = utteranceEdits ?? {},
        speakerOverrides = speakerOverrides ?? {},
        generalNotes = generalNotes ?? '';

  factory SessionMetadata.fromJson(Map<String, dynamic> j) => SessionMetadata(
        title: j['title'] as String?,
        durationMs: j['duration_ms'] as int?,
        labels: (j['labels'] as List?)?.cast<String>() ?? [],
        speakerNames: (j['speaker_names'] as Map?)?.cast<String, String>() ?? {},
        speakerNamesAuto: (j['speaker_names_auto'] as Map?)?.cast<String, String>() ?? {},
        utteranceEdits: (j['utterance_edits'] as Map?)?.cast<String, String>() ?? {},
        speakerOverrides: (j['speaker_overrides'] as Map?)?.cast<String, String>() ?? {},
        generalNotes: j['general_notes'] as String? ?? '',
        transcriptNotes: (j['transcript_notes'] as List?)
                ?.map((e) => NoteEntry(
                      timestampMs: ((e['timestamp_s'] as num) * 1000).round(),
                      text: e['text'] as String,
                      title: e['title'] as String?,
                    ))
                .toList() ??
            [],
      );

  Map<String, dynamic> toJson() => {
        if (title != null) 'title': title,
        if (durationMs != null) 'duration_ms': durationMs,
        'labels': labels,
        'speaker_names': speakerNames,
        'speaker_names_auto': speakerNamesAuto,
        'utterance_edits': utteranceEdits,
        'speaker_overrides': speakerOverrides,
        'general_notes': generalNotes,
        'transcript_notes': transcriptNotes
            .map((n) => {'timestamp_s': n.timestampMs / 1000.0, 'text': n.text, if (n.title != null) 'title': n.title})
            .toList(),
      };
}

class MetadataService {
  static File _file(String sessionDir) => File(p.join(sessionDir, 'metadata.json'));

  static Future<SessionMetadata> read(String sessionDir) async {
    final f = _file(sessionDir);
    if (!await f.exists()) return SessionMetadata();
    return SessionMetadata.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  }

  static Future<void> write(String sessionDir, SessionMetadata meta) async {
    await _file(sessionDir).writeAsString(jsonEncode(meta.toJson()));
  }

  /// Devuelve todas las etiquetas usadas en sesiones locales, ordenadas por sesión más reciente.
  static Future<List<String>> recentLabels() async {
    final dirs = await FileService.listSessionDirs();
    final seen = <String>{};
    final result = <String>[];
    for (final dir in dirs) {
      final meta = await read(dir);
      for (final label in meta.labels) {
        if (seen.add(label)) result.add(label);
      }
    }
    return result;
  }
}
