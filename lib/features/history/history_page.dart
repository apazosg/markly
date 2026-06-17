import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../../shared/api_service.dart';
import '../../shared/csv_service.dart';
import '../../shared/foreground_service.dart';
import '../../shared/metadata_service.dart';
import 'transcript_page.dart';
import '../../shared/file_service.dart';
import '../recording/models/note_entry.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<_Session> _sessions = [];
  bool _loading = true;
  String _query = '';
  final _searchCtrl = TextEditingController();

  // Modo selección para fusionar
  bool _selectMode = false;
  final List<String> _selectedIds = []; // serverIds en orden de selección

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<_Session> get _visibleSessions {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _sessions;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final scored = <({_Session session, double score})>[];
    for (final s in _sessions) {
      final score = _scoreSession(s, tokens);
      if (score > 0) scored.add((session: s, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.session).toList();
  }

  static double _scoreSession(_Session s, List<String> tokens) {
    double score = 0;
    final title = s.displayTitle.toLowerCase();
    final dateText = s.dateSearchText.toLowerCase();
    for (final t in tokens) {
      if (title == t) {
        score += 4;
      } else if (title.contains(t)) {
        score += 2;
      }
      for (final label in s.meta.labels) {
        final l = label.toLowerCase();
        if (l == t) {
          score += 3;
        } else if (l.contains(t)) {
          score += 1.5;
        }
      }
      if (dateText.contains(t)) score += 2;
      for (final note in [...s.notes, ...s.meta.transcriptNotes]) {
        if (note.text.toLowerCase().contains(t)) score += 0.5;
      }
    }
    return score;
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    // 1. Sesiones locales
    final dirs = await FileService.listSessionDirs();
    final localSessions = <_Session>[];
    final localServerIds = <String>{};

    for (final dir in dirs) {
      // Windows graba .wav, Android .m4a
      final audio = [
        File(p.join(dir, 'audio.m4a')),
        File(p.join(dir, 'audio.wav')),
      ].firstWhere((f) => f.existsSync(), orElse: () => File(''));
      if (!audio.existsSync()) continue;
      final notesPath = p.join(dir, 'notes.csv');
      final uploadedFile = File(p.join(dir, '.uploaded'));
      String? serverId;
      if (await uploadedFile.exists()) {
        serverId = (await uploadedFile.readAsString()).trim();
        if (serverId.isEmpty) serverId = null;
        if (serverId != null) localServerIds.add(serverId);
      }
      final meta = await MetadataService.read(dir);
      localSessions.add(_Session(
        localId: p.basename(dir),
        serverId: serverId,
        audioPath: audio.path,
        notesPath: notesPath,
        sessionDir: dir,
        notes: await File(notesPath).exists() ? await CsvService.read(notesPath) : [],
        meta: meta,
      ));
    }

    // 2. Sesiones remotas + sync de metadata AI para sesiones locales subidas
    final remoteSessions = <_Session>[];
    try {
      final serverList = await ApiService().listSessions();
      final serverMap = { for (final s in serverList) s['id'] as String: s };

      // Enriquece sesiones locales con título/labels generados por IA si el usuario no los puso
      for (final session in localSessions) {
        final sid = session.serverId;
        if (sid == null || !serverMap.containsKey(sid)) continue;
        final s = serverMap[sid]!;
        session.transcriptStatus = s['transcript_status'] as String?;
        session.summaryStatus = s['summary_status'] as String?;
        session.audioAvailable = (s['audio_available'] as bool?) ?? true;
        session.meta.title ??= s['title'] as String?;
        if (session.meta.labels.isEmpty) {
          session.meta.labels = (s['labels'] as List?)?.cast<String>() ?? [];
        }
      }

      for (final s in serverList) {
        final sid = s['id'] as String;
        if (localServerIds.contains(sid)) continue;
        remoteSessions.add(_Session(
          localId: s['session_id'] as String,
          serverId: sid,
          audioPath: null,
          notesPath: null,
          sessionDir: null,
          notes: _notesFromServer(s),
          meta: _metaFromServer(s),
          transcriptStatus: s['transcript_status'] as String?,
          summaryStatus: s['summary_status'] as String?,
          audioAvailable: (s['audio_available'] as bool?) ?? true,
        ));
      }
    } catch (_) {
      // Sin red: mostramos solo lo local
    }

    final all = [...localSessions, ...remoteSessions]
      ..sort((a, b) => b.localId.compareTo(a.localId));

    if (mounted) setState(() { _sessions = all; _loading = false; });
  }

  Future<void> _deleteSession(_Session session) async {
    final hasLocal = session.sessionDir != null;
    final hasCloud = session.serverId != null;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar grabación'),
        content: Text(
          '¿Eliminar "${session.displayTitle}"?'
          '${hasLocal ? '\nSe borrará el audio y las notas locales.' : ''}'
          '${hasCloud ? '\nSe eliminará del servidor.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (hasLocal) await Directory(session.sessionDir!).delete(recursive: true);
    if (hasCloud) {
      try {
        await ApiService().deleteSession(session.serverId!);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error al eliminar del servidor: $e')),
          );
        }
      }
    }
    _load();
  }

  // Borra solo los archivos locales (audio + notas). La reunión sigue en el
  // servidor: tras recargar, la sesión aparece como remota. No toca el servidor.
  Future<void> _deleteLocalRecording(_Session session) async {
    if (session.sessionDir == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar audio del dispositivo'),
        content: const Text(
          'Se borrará el audio y las notas de este dispositivo. '
          'La reunión (transcripción, resumen y notas) se conserva en la nube.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (confirm != true) return;
    await Directory(session.sessionDir!).delete(recursive: true);
    _load();
  }

  void _openTranscript(_Session session) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => TranscriptPage(
        serverId: session.serverId!,
        sessionLabel: session.displayTitle,
        sessionDir: session.sessionDir,
      ),
    ));
  }

  void _showError(String message) {
    if (!mounted) return;
    final isQuota = message.contains('402') || message.contains('Límite mensual');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isQuota
          ? 'Has alcanzado el límite mensual de créditos. Revisa tu cuenta.'
          : message),
      backgroundColor: Theme.of(context).colorScheme.error,
      duration: Duration(seconds: isQuota ? 5 : 3),
    ));
  }

  Future<void> _uploadSession(_Session session) async {
    setState(() { session.uploading = true; session.uploadProgress = 0; });
    int lastPct = -1;
    // Foreground service tipo dataSync: evita que Android suspenda el proceso si
    // el usuario minimiza la app durante la subida (cortaba el socket → error).
    await ForegroundService.start('Subiendo grabación…', type: 'dataSync');
    try {
      final serverId = await ApiService().uploadSession(
          session.audioPath!, session.notesPath!,
          labels: session.meta.labels,
          onProgress: (p) {
            // Throttle: solo redibujar cuando cambia el porcentaje entero.
            final pct = (p * 100).floor();
            if (pct != lastPct && mounted) {
              lastPct = pct;
              setState(() => session.uploadProgress = p);
            }
          });
      await File(p.join(session.sessionDir!, '.uploaded')).writeAsString(serverId);
      setState(() { session.serverId = serverId; session.uploading = false; });
      // Push metadata already stored locally
      await _pushMetadata(session);
    } catch (e) {
      setState(() => session.uploading = false);
      _showError('Error al subir: $e');
    } finally {
      await ForegroundService.stop();
    }
  }

  Future<void> _editTitle(_Session session) async {
    final ctrl = TextEditingController(text: session.meta.title ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Título de la grabación'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ej: Reunión de sprint'),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null) return;
    setState(() => session.meta.title = result.trim().isEmpty ? null : result.trim());
    if (session.sessionDir != null) await MetadataService.write(session.sessionDir!, session.meta);
    await _pushMetadata(session);
  }

  Future<void> _editLabels(_Session session) async {
    final recent = await MetadataService.recentLabels();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _LabelsSheet(
        current: session.meta.labels,
        suggestions: recent.where((l) => !session.meta.labels.contains(l)).toList(),
        onChanged: (labels) async {
          setState(() => session.meta.labels = labels);
          if (session.sessionDir != null) await MetadataService.write(session.sessionDir!, session.meta);
          await _pushMetadata(session);
        },
      ),
    );
  }

  Future<void> _reprocessSession(_Session session) async {
    setState(() => session.reprocessing = true);
    try {
      // Si el servidor ya purgó el audio y la transcripción falló, re-subimos la
      // copia local (bajo foreground service, como la subida normal); en cualquier
      // otro caso el reproceso es server-side (re-transcribir o solo re-resumir).
      final needsReupload = !session.audioAvailable &&
          session.transcriptStatus != 'done' &&
          session.hasLocalAudio;
      if (needsReupload) {
        await ForegroundService.start('Subiendo grabación…', type: 'dataSync');
        try {
          await ApiService().reattachAudio(session.serverId!, session.audioPath!);
        } finally {
          await ForegroundService.stop();
        }
      } else {
        await ApiService().reprocessSession(session.serverId!);
      }
      while (mounted) {
        await Future.delayed(const Duration(seconds: 2));
        final data = await ApiService().getSession(session.serverId!);
        final tStatus = data['transcript_status'] as String?;
        final sStatus = data['summary_status'] as String?;
        if (tStatus != 'pending' && sStatus != 'pending') {
          if (mounted) {
            setState(() {
              session.transcriptStatus = tStatus;
              session.summaryStatus = sStatus;
              session.reprocessing = false;
            });
          }
          break;
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => session.reprocessing = false);
        _showError('Error al re-analizar: $e');
      }
    }
  }

  Future<void> _pushMetadata(_Session session) async {
    if (session.serverId == null) return;
    try {
      await ApiService().updateMetadata(session.serverId!, {
        'title': session.meta.title ?? '',
        'labels': session.meta.labels,
        'speaker_names': session.meta.speakerNames,
        if (session.meta.durationMs != null) 'duration_ms': session.meta.durationMs,
        'transcript_notes': session.meta.transcriptNotes.map((n) => {
          'timestamp_s': n.timestampMs / 1000.0,
          'text': n.text,
          if (n.title != null) 'title': n.title,
        }).toList(),
      });
    } catch (_) {
      // No crítico: la metadata se sincronizará en la próxima edición
    }
  }

  void _toggleSelect(_Session session) {
    if (session.serverId == null) return;
    setState(() {
      if (_selectedIds.contains(session.serverId)) {
        _selectedIds.remove(session.serverId);
        if (_selectedIds.isEmpty) _selectMode = false;
      } else if (_selectedIds.length < 2) {
        _selectedIds.add(session.serverId!);
      }
    });
  }

  void _exitSelectMode() => setState(() { _selectMode = false; _selectedIds.clear(); });

  Future<void> _mergeSelected() async {
    if (_selectedIds.length != 2) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fusionar grabaciones'),
        content: const Text(
          'Se creará una nueva sesión con el audio concatenado en el orden seleccionado. '
          'Las grabaciones originales no se eliminarán. Se retranscribirá desde cero.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fusionar')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    _exitSelectMode();
    try {
      await ApiService().mergeSessions(_selectedIds);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fusión iniciada. La transcripción llegará en unos minutos.')),
        );
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al fusionar: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canMerge = _selectedIds.length == 2;
    return Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelectMode),
              title: Text('${_selectedIds.length} seleccionada${_selectedIds.length == 1 ? '' : 's'}'),
              actions: [
                TextButton.icon(
                  icon: const Icon(Icons.merge),
                  label: const Text('Fusionar'),
                  onPressed: canMerge ? _mergeSelected : null,
                ),
              ],
            )
          : AppBar(
        title: const Text('Historial'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Actualizar'),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Buscar por título o etiquetas…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () { _searchCtrl.clear(); setState(() => _query = ''); },
                      ),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                filled: true,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _visibleSessions.isEmpty
                    ? Center(
                        child: Text(
                          _query.trim().isEmpty
                              ? 'Todavía no hay grabaciones.'
                              : 'Sin resultados para "$_query".',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: Theme.of(context).colorScheme.outline),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: _visibleSessions.length,
                        itemBuilder: (context, i) {
                          final s = _visibleSessions[i];
                          final isSelected = s.serverId != null && _selectedIds.contains(s.serverId);
                          return _SessionCard(
                            session: s,
                            selected: isSelected,
                            selectMode: _selectMode,
                            onLongPress: s.serverId != null
                                ? () {
                                    setState(() { _selectMode = true; });
                                    _toggleSelect(s);
                                  }
                                : null,
                            onTapInSelectMode: () => _toggleSelect(s),
                            onDelete: () => _deleteSession(s),
                            // Solo cuando ya está procesada (transcript + resumen) y
                            // aún quedan archivos locales que liberar.
                            onDeleteLocal: s.isUploaded &&
                                    s.sessionDir != null &&
                                    s.transcriptStatus == 'done' &&
                                    s.summaryStatus == 'done'
                                ? () => _deleteLocalRecording(s)
                                : null,
                            onUpload: s.isUploaded || s.uploading || s.isRemoteOnly
                                ? null
                                : () => _uploadSession(s),
                            onViewTranscript: s.isUploaded ? () => _openTranscript(s) : null,
                            // Con transcript hecho: siempre (re-resumen, sin audio).
                            // En 'error' hace falta re-transcribir → necesita audio
                            // en el servidor o, si se purgó, copia local para re-subir.
                            onReprocess: s.isUploaded && !s.reprocessing &&
                                    (s.transcriptStatus == 'done' ||
                                        (s.transcriptStatus == 'error' &&
                                            (s.audioAvailable || s.hasLocalAudio)))
                                ? () => _reprocessSession(s)
                                : null,
                            onEditTitle: () => _editTitle(s),
                            onEditLabels: () => _editLabels(s),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Data ─────────────────────────────────────────────────────────────────────

class _Session {
  final String localId;
  String? serverId;
  final String? audioPath;
  final String? notesPath;
  final String? sessionDir;
  final List<NoteEntry> notes;
  bool uploading = false;
  double uploadProgress = 0; // 0..1 mientras uploading; 1 = enviado, esperando al servidor
  bool reprocessing = false;
  SessionMetadata meta;
  String? transcriptStatus;
  String? summaryStatus;
  // False cuando el audio ya no está en el servidor (purgado por retención):
  // se puede re-resumir pero no re-transcribir.
  bool audioAvailable;

  _Session({
    required this.localId,
    required this.serverId,
    required this.audioPath,
    required this.notesPath,
    required this.sessionDir,
    required this.notes,
    required this.meta,
    this.transcriptStatus,
    this.summaryStatus,
    this.audioAvailable = true,
  });

  bool get isUploaded => serverId != null;
  bool get isRemoteOnly => sessionDir == null;
  bool get hasLocalAudio => audioPath != null;

  String get displayTitle => meta.title ?? _dateLabel;

  String get _dateLabel {
    try {
      return DateFormat('d MMM yyyy · HH:mm:ss').format(_parsedDate!);
    } catch (_) { return localId; }
  }

  DateTime? get _parsedDate {
    try {
      final parts = localId.split('_');
      final d = parts[0]; final t = parts[1];
      return DateTime(
        int.parse(d.substring(0, 4)), int.parse(d.substring(4, 6)), int.parse(d.substring(6, 8)),
        int.parse(t.substring(0, 2)), int.parse(t.substring(2, 4)), int.parse(t.substring(4, 6)),
      );
    } catch (_) { return null; }
  }

  // Texto de búsqueda por fecha en español: "9 junio 2025 lunes"
  String get dateSearchText {
    final dt = _parsedDate;
    if (dt == null) return '';
    return '${dt.day} ${DateFormat('MMMM', 'es').format(dt)} ${dt.year} ${DateFormat('EEEE', 'es').format(dt)}';
  }

  String? get durationLabel {
    final ms = meta.durationMs;
    if (ms == null || ms <= 0) return null;
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

List<NoteEntry> _notesFromServer(Map<String, dynamic> s) {
  final list = (s['notes_content'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  return list.map((n) => NoteEntry(
    timestampMs: (n['timestamp_ms'] as num?)?.toInt() ?? 0,
    text: n['text'] as String? ?? '',
    title: n['title'] as String?,
  )).toList();
}

SessionMetadata _metaFromServer(Map<String, dynamic> s) => SessionMetadata(
  title: s['title'] as String?,
  labels: (s['labels'] as List?)?.cast<String>() ?? [],
  speakerNames: (s['speaker_names'] as Map?)?.cast<String, String>() ?? {},
  durationMs: s['duration_ms'] as int?,
  transcriptNotes: ((s['transcript_notes'] as List?)?.cast<Map<String, dynamic>>() ?? [])
      .map((n) => NoteEntry(
        timestampMs: ((n['timestamp_s'] as num?) ?? 0.0).toDouble().round() * 1000,
        text: n['text'] as String? ?? '',
        title: n['title'] as String?,
      )).toList(),
);

// ── Labels bottom sheet ──────────────────────────────────────────────────────

class _LabelsSheet extends StatefulWidget {
  final List<String> current;
  final List<String> suggestions;
  final void Function(List<String>) onChanged;
  const _LabelsSheet({required this.current, required this.suggestions, required this.onChanged});

  @override
  State<_LabelsSheet> createState() => _LabelsSheetState();
}

class _LabelsSheetState extends State<_LabelsSheet> {
  late List<String> _labels;
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _labels = List.from(widget.current);
  }

  void _add(String label) {
    final l = label.trim().toLowerCase();
    if (l.isEmpty || _labels.contains(l)) return;
    setState(() => _labels.add(l));
    widget.onChanged(_labels);
  }

  void _remove(String label) {
    setState(() => _labels.remove(label));
    widget.onChanged(_labels);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Etiquetas', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 4, children: _labels.map((l) => Chip(
          label: Text(l),
          onDeleted: () => _remove(l),
          deleteIconColor: Theme.of(context).colorScheme.outline,
        )).toList()),
        if (widget.suggestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Usadas recientemente', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: widget.suggestions.take(12).map((l) => ActionChip(
            label: Text(l),
            onPressed: () => _add(l),
          )).toList()),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          decoration: InputDecoration(
            hintText: 'Nueva etiqueta',
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () { _add(_ctrl.text); _ctrl.clear(); }),
          ),
          textCapitalization: TextCapitalization.none,
          onSubmitted: (v) { _add(v); _ctrl.clear(); },
        ),
      ]),
    );
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
}

// ── Session card ─────────────────────────────────────────────────────────────

class _SessionCard extends StatelessWidget {
  final _Session session;
  final bool selected;
  final bool selectMode;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapInSelectMode;
  final VoidCallback? onDelete;
  final VoidCallback? onDeleteLocal;
  final VoidCallback? onUpload;
  final VoidCallback? onViewTranscript;
  final VoidCallback? onReprocess;
  final VoidCallback onEditTitle;
  final VoidCallback onEditLabels;

  const _SessionCard({
    required this.session,
    required this.onEditTitle,
    required this.onEditLabels,
    this.selected = false,
    this.selectMode = false,
    this.onLongPress,
    this.onTapInSelectMode,
    this.onDelete,
    this.onDeleteLocal,
    this.onUpload,
    this.onViewTranscript,
    this.onReprocess,
  });

  Future<void> _share() async {
    final files = [XFile(session.audioPath!)];
    if (await File(session.notesPath!).exists()) files.add(XFile(session.notesPath!));
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Markly · ${session.displayTitle}'),
    );
  }

  void _openFolder() {
    if (Platform.isWindows) Process.run('explorer', [session.sessionDir!]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      onLongPress: onLongPress,
      onTap: selectMode ? onTapInSelectMode : null,
      child: Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: selected ? colors.primaryContainer.withValues(alpha: 0.35) : null,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colors.primary, width: 2),
            )
          : null,
      child: ExpansionTile(
        leading: selectMode
            ? Checkbox(
                value: selected,
                onChanged: (_) => onTapInSelectMode?.call(),
              )
            : _CloudStatus(session: session),
        title: Text(session.displayTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: _CardSubtitle(session: session),
        children: [
          // ── Acciones de edición ──
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(children: [
              TextButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Título'),
                onPressed: onEditTitle,
              ),
              TextButton.icon(
                icon: const Icon(Icons.label_outlined, size: 16),
                label: const Text('Etiquetas'),
                onPressed: onEditLabels,
              ),
            ]),
          ),

          // ── Acciones principales ──
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(children: [
              if (session.uploading)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        // Determinado mientras sube; indeterminado al esperar al servidor.
                        value: (session.uploadProgress > 0 && session.uploadProgress < 1)
                            ? session.uploadProgress
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      session.uploadProgress >= 1
                          ? 'Procesando…'
                          : 'Subiendo ${(session.uploadProgress * 100).round()}%',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ]),
                )
              else if (!session.isUploaded && !session.isRemoteOnly)
                TextButton.icon(
                  icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: const Text('Subir'),
                  onPressed: onUpload,
                ),
              if (onViewTranscript != null)
                TextButton.icon(
                  icon: const Icon(Icons.article_outlined, size: 16),
                  label: const Text('Detalles'),
                  onPressed: onViewTranscript,
                ),
              if (session.reprocessing)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (onReprocess != null)
                TextButton.icon(
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Re-analizar'),
                  onPressed: onReprocess,
                ),
              const Spacer(),
              if (!session.isRemoteOnly && Platform.isWindows)
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 20),
                  tooltip: 'Abrir carpeta',
                  onPressed: _openFolder,
                ),
              if (!session.isRemoteOnly)
                IconButton(
                  icon: const Icon(Icons.share, size: 20),
                  tooltip: 'Compartir',
                  onPressed: _share,
                ),
              if (onDeleteLocal != null)
                IconButton(
                  icon: const Icon(Icons.phonelink_erase_outlined, size: 20),
                  tooltip: 'Borrar audio del dispositivo (la reunión se conserva en la nube)',
                  onPressed: onDeleteLocal,
                ),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 20, color: colors.error),
                tooltip: 'Eliminar',
                onPressed: onDelete,
              ),
            ]),
          ),
        ],
      ),
    )); // Card + GestureDetector
  }
}

class _CloudStatus extends StatelessWidget {
  final _Session session;
  const _CloudStatus({required this.session});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    if (session.isRemoteOnly) return Icon(Icons.cloud_outlined, color: color.primary);
    if (session.isUploaded) return Icon(Icons.cloud_done_outlined, color: color.primary);
    return const Icon(Icons.mic_none);
  }
}

class _CardSubtitle extends StatelessWidget {
  final _Session session;
  const _CardSubtitle({required this.session});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: colors.outline);
    final n = session.notes.length;

    final metaLine = [
      session._dateLabel,
      if (session.durationLabel != null) session.durationLabel!,
      '$n nota${n != 1 ? 's' : ''}',
    ].join(' · ');

    final status = _statusLine(colors);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(metaLine, style: style),
      if (status != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(status.$2, size: 13, color: status.$3),
            const SizedBox(width: 4),
            Text(status.$1, style: TextStyle(fontSize: 12, color: status.$3, fontWeight: FontWeight.w500)),
          ]),
        ),
      if (session.meta.labels.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 4,
            children: session.meta.labels
                .map((l) => Chip(
                      label: Text(l, style: const TextStyle(fontSize: 11)),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ))
                .toList(),
          ),
        ),
    ]);
  }

  // (texto, icono, color) del estado de procesado; null cuando ya está todo listo.
  (String, IconData, Color)? _statusLine(ColorScheme colors) {
    if (!session.isUploaded && !session.isRemoteOnly) return null;
    final t = session.transcriptStatus;
    final s = session.summaryStatus;
    if (t == 'pending') return ('Transcribiendo…', Icons.graphic_eq, colors.primary);
    if (t == 'error') return ('Error de transcripción', Icons.error_outline, colors.error);
    if (s == 'pending') return ('Resumiendo…', Icons.auto_awesome, colors.primary);
    if (s == 'error') return ('Resumen pendiente · re-analizar', Icons.auto_awesome_outlined, colors.error);
    return null;
  }
}
