import 'dart:io';
import '../features/recording/models/note_entry.dart';

class CsvService {
  static const _header = 'timestamp_ms,timestamp_hms,title,note\n';

  static Future<void> write(String path, List<NoteEntry> notes) async {
    final buffer = StringBuffer(_header);
    for (final note in notes) {
      final title = _escapeCsv(note.title ?? '');
      final text = _escapeCsv(note.text);
      buffer.writeln('${note.timestampMs},${note.formattedTimestamp},$title,$text');
    }
    await File(path).writeAsString(buffer.toString());
  }

  static Future<List<NoteEntry>> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return [];
    final lines = await file.readAsLines();
    if (lines.length <= 1) return [];
    final notes = <NoteEntry>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = _parseCsvLine(line);
      if (parts.length < 3) continue;
      final ms = int.tryParse(parts[0]);
      if (ms == null) continue;
      // Support old format (3 cols: ms, hms, note) and new (4 cols: ms, hms, title, note)
      final hasTitle = parts.length >= 4;
      notes.add(NoteEntry(
        timestampMs: ms,
        title: hasTitle && parts[2].isNotEmpty ? parts[2] : null,
        text: hasTitle ? parts[3] : parts[2],
      ));
    }
    return notes;
  }

  static String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  static List<String> _parseCsvLine(String line) {
    final result = <String>[];
    var inQuotes = false;
    final current = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        result.add(current.toString());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    result.add(current.toString());
    return result;
  }
}
