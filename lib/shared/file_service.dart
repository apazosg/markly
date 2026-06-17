import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class FileService {
  static final _idFormat = DateFormat('yyyyMMdd_HHmmss');

  static Future<SessionPaths> createSessionPaths() async {
    final base = await getApplicationDocumentsDirectory();
    final id = _idFormat.format(DateTime.now());
    final dir = p.join(base.path, 'Markly', 'sessions', id);
    await Directory(dir).create(recursive: true);
    // Windows codifica AAC .m4a vía Media Foundation a 48 kHz (16 kHz no va fiable
    // en MF, pero 48 kHz sí). Android graba AAC .m4a directamente.
    const audioExt = 'm4a';
    return SessionPaths(
      sessionId: id,
      sessionDir: dir,
      audioPath: p.join(dir, 'audio.$audioExt'),
      notesPath: p.join(dir, 'notes.csv'),
    );
  }

  static Future<List<String>> listSessionDirs() async {
    final base = await getApplicationDocumentsDirectory();
    final sessionsDir = Directory(p.join(base.path, 'Markly', 'sessions'));
    if (!await sessionsDir.exists()) return [];
    final dirs = await sessionsDir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.path)
        .toList();
    dirs.sort((a, b) => b.compareTo(a));
    return dirs;
  }
}

class SessionPaths {
  final String sessionId;
  final String sessionDir;
  final String audioPath;
  final String notesPath;

  const SessionPaths({
    required this.sessionId,
    required this.sessionDir,
    required this.audioPath,
    required this.notesPath,
  });
}
