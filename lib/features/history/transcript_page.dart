import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../../shared/api_service.dart';
import '../../shared/csv_service.dart';
import '../../shared/markdown.dart';
import '../../shared/metadata_service.dart';
import '../recording/models/note_entry.dart';

class TranscriptPage extends StatefulWidget {
  final String serverId;
  final String sessionLabel;
  final String? sessionDir;

  const TranscriptPage({
    super.key,
    required this.serverId,
    required this.sessionLabel,
    this.sessionDir,
  });

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  _LoadState _loadState = _LoadState.loading;
  String? _error;

  // Datos del servidor
  String? _summary;
  List<String> _topics = [];
  List<_Utterance> _utterances = [];

  // Metadata (local + servidor)
  SessionMetadata _meta = SessionMetadata();

  // Timeline (transcripción) y notas de grabación
  List<_TimelineItem> _timeline = [];
  List<GlobalKey> _itemKeys = [];
  List<NoteEntry> _recordingNotes = [];

  final _generalNotesController = TextEditingController();

  // Búsqueda
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _searching = false;
  String _searchQuery = '';
  List<int> _matchIndices = [];
  int _currentMatchIdx = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _generalNotesController.dispose();
    super.dispose();
  }

  // ── Load ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loadState = _LoadState.loading; _error = null; });
    try {
      final futures = <Future>[
        ApiService().getSession(widget.serverId),
        if (widget.sessionDir != null) ...[
          MetadataService.read(widget.sessionDir!),
          CsvService.read('${widget.sessionDir}/notes.csv'),
        ],
      ];
      final results = await Future.wait(futures);
      final data = results[0] as Map<String, dynamic>;

      final SessionMetadata meta;
      final List<NoteEntry> recordingNotes;
      if (widget.sessionDir != null) {
        meta = results[1] as SessionMetadata;
        recordingNotes = results[2] as List<NoteEntry>;
      } else {
        meta = _metaFromResponse(data);
        recordingNotes = _notesFromResponse(data);
      }

      final status = data['transcript_status'] as String?;
      if (status == 'pending') {
        setState(() { _loadState = _LoadState.pending; _meta = meta; });
        return;
      }
      if (status == 'error') {
        setState(() { _loadState = _LoadState.error; _error = data['transcript'] as String?; });
        return;
      }

      // Utterances (preferimos las agrupadas de Deepgram, fallback a palabras)
      final List<_Utterance> utterances;
      final rawUtterances = (data['utterances_data'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      if (rawUtterances.isNotEmpty) {
        utterances = rawUtterances.map((u) => _Utterance(
          speaker: u['speaker'] as String,
          start: (u['start'] as num).toDouble(),
          end: (u['end'] as num).toDouble(),
          text: u['text'] as String,
        )).toList();
      } else {
        final raw = data['diarization'] as String?;
        if (raw == null || raw.isEmpty) {
          utterances = [];
        } else {
          utterances = _groupByWords((jsonDecode(raw) as List).cast<Map<String, dynamic>>());
        }
      }

      // Párrafos (puntos de corte internos, omitimos el primero)
      final rawParas = (data['paragraphs_data'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final paragraphStarts = rawParas.map((p) => (p['start'] as num).toDouble()).toList();
      final paragraphBreaks = paragraphStarts.length > 1
          ? paragraphStarts.skip(1).toSet()
          : <double>{};

      setState(() {
        _meta = meta;
        _summary = data['summary'] as String?;
        _topics = (data['topics'] as List?)?.cast<String>() ?? [];
        _utterances = utterances;
        _recordingNotes = recordingNotes;
        _setTimeline(_buildTimeline(utterances, paragraphBreaks, meta.transcriptNotes));
        _loadState = _LoadState.done;
      });
      if (_generalNotesController.text != meta.generalNotes) {
        _generalNotesController.text = meta.generalNotes;
      }
    } catch (e) {
      setState(() { _loadState = _LoadState.error; _error = e.toString(); });
    }
  }

  void _setTimeline(List<_TimelineItem> items) {
    _timeline = items;
    _itemKeys = List.generate(items.length, (_) => GlobalKey());
    if (_searchQuery.isNotEmpty) _rebuildMatchIndices();
  }

  // ── Timeline ─────────────────────────────────────────────────────────────

  List<_TimelineItem> _buildTimeline(
    List<_Utterance> utterances,
    Set<double> paragraphBreaks,
    List<NoteEntry> transcriptNotes,
  ) {
    final items = <_TimelineItem>[];
    for (final u in utterances) {
      if (paragraphBreaks.any((ps) => (u.start - ps).abs() < 1.0)) {
        // El corte de párrafo solo aporta si cambia de hablante; dentro del
        // mismo hablante es ruido.
        final prev = items.isNotEmpty ? items.last : null;
        final sameSpeaker = prev is _UtteranceItem && prev.utterance.speaker == u.speaker;
        if (!sameSpeaker) items.add(_SectionBreak(u.start - 0.0001));
      }
      items.add(_UtteranceItem(u));
    }

    final notes = transcriptNotes
        .map((n) => _NoteItem(n.timestampMs / 1000.0, n.text, n.title, fromRecording: false))
        .cast<_TimelineItem>();

    return [...items, ...notes]..sort((a, b) => a.timestampS.compareTo(b.timestampS));
  }

  List<_Utterance> _groupByWords(List<Map<String, dynamic>> words) {
    final result = <_Utterance>[];
    String? speaker;
    final buffer = StringBuffer();
    double start = 0, end = 0;
    for (final w in words) {
      final s = w['speaker'] as String? ?? '?';
      if (s != speaker) {
        if (speaker != null && buffer.isNotEmpty) {
          result.add(_Utterance(speaker: speaker, start: start, end: end, text: buffer.toString().trim()));
        }
        speaker = s;
        start = (w['start'] as num).toDouble();
        buffer.clear();
      }
      end = (w['end'] as num).toDouble();
      buffer.write('${w['text']} ');
    }
    if (speaker != null && buffer.isNotEmpty) {
      result.add(_Utterance(speaker: speaker, start: start, end: end, text: buffer.toString().trim()));
    }
    return result;
  }

  // ── Metadata save ─────────────────────────────────────────────────────────

  Future<void> _saveMeta() async {
    final dir = widget.sessionDir;
    if (dir != null) await MetadataService.write(dir, _meta);
    try {
      await ApiService().updateMetadata(widget.serverId, {
        'speaker_names': _meta.speakerNames,
        'utterance_edits': _meta.utteranceEdits,
        'speaker_overrides': _meta.speakerOverrides,
        'general_notes': _meta.generalNotes,
        'transcript_notes': _meta.transcriptNotes.map((n) => {
          'timestamp_s': n.timestampMs / 1000.0,
          'text': n.text,
          if (n.title != null) 'title': n.title,
        }).toList(),
      });
    } catch (_) {}
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _renameSpeaker(String speakerId) async {
    final current = _meta.speakerNames[speakerId] ?? '';
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hablante $speakerId'),
        content: TextField(
          controller: ctrl, autofocus: true,
          decoration: const InputDecoration(hintText: 'Nombre del hablante'),
          textCapitalization: TextCapitalization.words,
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
    setState(() {
      if (result.trim().isEmpty) {
        _meta.speakerNames.remove(speakerId);
      } else {
        _meta.speakerNames[speakerId] = result.trim();
      }
    });
    await _saveMeta();
  }

  Future<void> _onTapSpeaker(_Utterance utterance) async {
    final effectiveSpeaker = _meta.speakerOverrides[_editKey(utterance.start)] ?? utterance.speaker;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(_meta.speakerNames[effectiveSpeaker] ?? 'Hablante $effectiveSpeaker'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const Text('Renombrar hablante'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'reassign'),
            child: const Text('Cambiar hablante de este párrafo'),
          ),
        ],
      ),
    );
    if (action == 'rename') {
      await _renameSpeaker(effectiveSpeaker);
    } else if (action == 'reassign') {
      await _reassignUtterance(utterance);
    }
  }

  Future<void> _reassignUtterance(_Utterance utterance) async {
    final knownSpeakers = _utterances.map((u) => u.speaker).toSet().toList()..sort();
    final key = _editKey(utterance.start);
    final current = _meta.speakerOverrides[key] ?? utterance.speaker;

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Asignar hablante'),
        children: [
          for (final sid in knownSpeakers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, sid),
              child: Row(children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: _colorFor(sid).withValues(alpha: 0.2),
                  child: Text(
                    _meta.speakerNames[sid]?.substring(0, 1).toUpperCase() ?? sid,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _colorFor(sid)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_meta.speakerNames[sid] ?? 'Hablante $sid'),
                if (sid == current) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.check, size: 14),
                ],
              ]),
            ),
        ],
      ),
    );
    if (selected == null) return;
    setState(() {
      if (selected == utterance.speaker) {
        _meta.speakerOverrides.remove(key);
      } else {
        _meta.speakerOverrides[key] = selected;
      }
    });
    await _saveMeta();
  }

  Future<void> _editUtterance(_Utterance utterance) async {
    final key = _editKey(utterance.start);
    final current = _meta.utteranceEdits[key] ?? utterance.text;
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar texto'),
        content: TextField(
          controller: ctrl, autofocus: true, maxLines: null,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          if (_meta.utteranceEdits.containsKey(key))
            TextButton(onPressed: () => Navigator.pop(ctx, '\x00'), child: const Text('Restaurar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null) return;
    setState(() {
      if (result == '\x00' || result.trim() == utterance.text) {
        _meta.utteranceEdits.remove(key);
      } else {
        _meta.utteranceEdits[key] = result.trim();
      }
    });
    if (_searchQuery.isNotEmpty) _rebuildMatchIndices();
    await _saveMeta();
  }

  Future<void> _addNote(double atSeconds) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Nota en ${_formatTime(atSeconds)}'),
        content: TextField(
          controller: ctrl, autofocus: true, maxLines: null,
          decoration: const InputDecoration(hintText: 'Escribe la nota…'),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Añadir')),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result.trim().isEmpty) return;

    final note = NoteEntry(timestampMs: (atSeconds * 1000).round(), text: result.trim());
    _meta.transcriptNotes.add(note);
    final newItem = _NoteItem(atSeconds, note.text, null, fromRecording: false);
    final newTimeline = List<_TimelineItem>.from(_timeline);
    final idx = newTimeline.indexWhere((item) => item.timestampS > atSeconds);
    if (idx == -1) {
      newTimeline.add(newItem);
    } else {
      newTimeline.insert(idx, newItem);
    }
    setState(() => _setTimeline(newTimeline));
    await _saveMeta();
  }

  // ── Search ────────────────────────────────────────────────────────────────

  void _startSearch() => setState(() => _searching = true);

  void _stopSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _searchQuery = '';
      _matchIndices = [];
      _currentMatchIdx = 0;
    });
  }

  void _onSearchChanged(String value) {
    final q = value.trim().toLowerCase();
    setState(() { _searchQuery = q; _currentMatchIdx = 0; });
    _rebuildMatchIndices();
    if (_matchIndices.isNotEmpty) _scrollToMatch(0);
  }

  void _rebuildMatchIndices() {
    if (_searchQuery.isEmpty) { _matchIndices = []; return; }
    final indices = <int>[];
    for (int i = 0; i < _timeline.length; i++) {
      final item = _timeline[i];
      final text = switch (item) {
        _UtteranceItem u => (_meta.utteranceEdits[_editKey(u.utterance.start)] ?? u.utterance.text).toLowerCase(),
        _NoteItem n      => n.text.toLowerCase(),
        _SectionBreak _  => '',
      };
      if (text.contains(_searchQuery)) indices.add(i);
    }
    setState(() => _matchIndices = indices);
  }

  void _nextMatch() {
    if (_matchIndices.isEmpty) return;
    final next = (_currentMatchIdx + 1) % _matchIndices.length;
    setState(() => _currentMatchIdx = next);
    _scrollToMatch(next);
  }

  void _prevMatch() {
    if (_matchIndices.isEmpty) return;
    final prev = (_currentMatchIdx - 1 + _matchIndices.length) % _matchIndices.length;
    setState(() => _currentMatchIdx = prev);
    _scrollToMatch(prev);
  }

  void _scrollToMatch(int matchIdx) {
    if (matchIdx >= _matchIndices.length) return;
    final timelineIdx = _matchIndices[matchIdx];
    if (timelineIdx >= _itemKeys.length) return;
    final ctx = _itemKeys[timelineIdx].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.25);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: switch (_loadState) {
        _LoadState.loading => const Center(child: CircularProgressIndicator()),
        _LoadState.pending => _pendingBody(),
        _LoadState.error   => _errorBody(),
        _LoadState.done    => TabBarView(
            controller: _tabController,
            children: [_summaryTab(), _transcriptTab(), _notesTab()],
          ),
      },
    );
  }

  AppBar _buildAppBar() {
    if (_searching) {
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _stopSearch),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Buscar en transcripción…', border: InputBorder.none),
          onChanged: _onSearchChanged,
        ),
        actions: [
          if (_matchIndices.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(child: Text('${_currentMatchIdx + 1}/${_matchIndices.length}',
                  style: const TextStyle(fontSize: 13))),
            ),
            IconButton(icon: const Icon(Icons.keyboard_arrow_up), onPressed: _prevMatch),
            IconButton(icon: const Icon(Icons.keyboard_arrow_down), onPressed: _nextMatch),
          ] else if (_searchQuery.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text('Sin resultados', style: TextStyle(fontSize: 13))),
            ),
        ],
      );
    }

    return AppBar(
      title: Text(widget.sessionLabel, overflow: TextOverflow.ellipsis),
      actions: [
        if (_loadState == _LoadState.done) ...[
          IconButton(icon: const Icon(Icons.search), onPressed: _startSearch, tooltip: 'Buscar'),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Recargar'),
        ],
      ],
      bottom: _loadState == _LoadState.done
          ? TabBar(
              controller: _tabController,
              tabs: const [Tab(text: 'Resumen'), Tab(text: 'Transcripción'), Tab(text: 'Notas')],
            )
          : null,
    );
  }

  // ── Summary tab ───────────────────────────────────────────────────────────

  Widget _summaryTab() => _SummaryTab(
    summary: _summary,
    topics: _topics,
    utterances: _utterances,
    speakerNames: _meta.speakerNames,
    onTapSpeaker: _renameSpeaker,
  );

  Widget _notesTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _SectionLabel('Notas generales'),
        const SizedBox(height: 8),
        TextField(
          controller: _generalNotesController,
          maxLines: null,
          minLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Añade notas, contexto o comentarios sobre esta reunión…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.all(12),
          ),
          onEditingComplete: _saveGeneralNotes,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _saveGeneralNotes,
            child: const Text('Guardar'),
          ),
        ),
        if (_recordingNotes.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SectionLabel('Notas de grabación'),
          const SizedBox(height: 8),
          for (final note in _recordingNotes) _buildRecordingNote(note),
        ],
      ],
    );
  }

  Widget _buildRecordingNote(NoteEntry note) {
    final ts = note.timestampMs / 1000;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_formatTime(ts),
            style: TextStyle(
                fontFamily: 'monospace', fontSize: 11,
                color: Theme.of(context).colorScheme.outline)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (note.title != null)
              Text(note.title!,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Text(note.text, style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      ]),
    );
  }

  Future<void> _saveGeneralNotes() async {
    _meta.generalNotes = _generalNotesController.text;
    await _saveMeta();
  }

  // ── Transcript tab ────────────────────────────────────────────────────────

  Widget _transcriptTab() {
    if (_timeline.isEmpty) {
      return Center(
        child: Text('Sin voces detectadas en esta grabación',
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      );
    }
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        for (int i = 0; i < _timeline.length; i++)
          KeyedSubtree(
            key: _itemKeys[i],
            child: _buildItem(_timeline[i], i),
          ),
      ],
    );
  }

  String _effectiveSpeaker(_Utterance u) =>
      _meta.speakerOverrides[_editKey(u.start)] ?? u.speaker;

  // Una intervención es "continuación" si el item anterior es del mismo
  // hablante (una nota o corte de párrafo intermedios la rompen).
  bool _continuesSpeaker(int idx) {
    if (idx == 0) return false;
    final prev = _timeline[idx - 1];
    final cur = _timeline[idx];
    if (prev is! _UtteranceItem || cur is! _UtteranceItem) return false;
    return _effectiveSpeaker(prev.utterance) == _effectiveSpeaker(cur.utterance);
  }

  Widget _buildItem(_TimelineItem item, int idx) {
    final isCurrentMatch = _matchIndices.isNotEmpty && _matchIndices[_currentMatchIdx] == idx;
    return switch (item) {
      _UtteranceItem u => _UtteranceTile(
          utterance: u.utterance,
          continuation: _continuesSpeaker(idx),
          effectiveSpeaker: _meta.speakerOverrides[_editKey(u.utterance.start)],
          editedText: _meta.utteranceEdits[_editKey(u.utterance.start)],
          speakerName: _meta.speakerNames[_meta.speakerOverrides[_editKey(u.utterance.start)] ?? u.utterance.speaker],
          searchQuery: _searchQuery,
          isCurrentMatch: isCurrentMatch,
          onTapSpeaker: () => _onTapSpeaker(u.utterance),
          onTapText: () => _editUtterance(u.utterance),
          onAddNote: () => _addNote(u.utterance.start),
        ),
      _NoteItem n     => _NoteTile(note: n, searchQuery: _searchQuery, isCurrentMatch: isCurrentMatch),
      _SectionBreak _ => const _SectionDivider(),
    };
  }

  Widget _pendingBody() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const CircularProgressIndicator(),
    const SizedBox(height: 16),
    const Text('Transcribiendo…'),
    const SizedBox(height: 8),
    TextButton(onPressed: _load, child: const Text('Comprobar de nuevo')),
  ]));

  Widget _errorBody() => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
    mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
    const SizedBox(height: 12),
    Text(_error ?? 'Error desconocido', textAlign: TextAlign.center),
    const SizedBox(height: 16),
    FilledButton(onPressed: _load, child: const Text('Reintentar')),
  ])));
}

// ── Summary tab widget ────────────────────────────────────────────────────

class _SummaryTab extends StatelessWidget {
  final String? summary;
  final List<String> topics;
  final List<_Utterance> utterances;
  final Map<String, String> speakerNames;
  final void Function(String speakerId)? onTapSpeaker;

  const _SummaryTab({
    required this.summary,
    required this.topics,
    required this.utterances,
    required this.speakerNames,
    this.onTapSpeaker,
  });

  @override
  Widget build(BuildContext context) {
    final speakerSeconds = <String, double>{};
    for (final u in utterances) {
      speakerSeconds[u.speaker] = (speakerSeconds[u.speaker] ?? 0) + (u.end - u.start);
    }
    final total = speakerSeconds.values.fold(0.0, (a, b) => a + b);
    final sortedSpeakers = speakerSeconds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final hasContent = summary != null || topics.isNotEmpty || sortedSpeakers.isNotEmpty;
    if (!hasContent) {
      return Center(child: Text('Sin datos de resumen',
          style: TextStyle(color: Theme.of(context).colorScheme.outline)));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (summary != null) ...[
          MarkdownBody(
            data: normalizeMarkdown(summary!),
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: Theme.of(context).textTheme.bodyMedium,
              listBullet: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (topics.isNotEmpty) ...[
          _SectionLabel('Temas detectados'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 6,
            children: topics.map((t) => Chip(
              label: Text(t, style: const TextStyle(fontSize: 12)),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            )).toList(),
          ),
          const SizedBox(height: 20),
        ],
        if (sortedSpeakers.isNotEmpty) ...[
          _SectionLabel('Hablantes'),
          const SizedBox(height: 8),
          ...sortedSpeakers.map((e) {
            final name = speakerNames[e.key] ?? 'Hablante ${e.key}';
            final pct = total > 0 ? (e.value / total * 100).round() : 0;
            final color = _colorFor(e.key);
            final secs = e.value.round();
            final label = secs >= 60
                ? '${secs ~/ 60}m ${secs % 60}s · $pct%'
                : '${secs}s · $pct%';
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                onTap: onTapSpeaker != null ? () => onTapSpeaker!(e.key) : null,
                borderRadius: BorderRadius.circular(8),
                child: Row(children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: color.withValues(alpha: 0.2),
                    child: Text(
                      name.substring(0, 1).toUpperCase(),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
                    ]),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: total > 0 ? e.value / total : 0,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ])),
                  if (onTapSpeaker != null)
                    Icon(Icons.edit_outlined, size: 14,
                        color: Theme.of(context).colorScheme.outline),
                ]),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        )),
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────

String _editKey(double startS) => (startS * 1000).round().toString();

SessionMetadata _metaFromResponse(Map<String, dynamic> data) => SessionMetadata(
  title: data['title'] as String?,
  labels: (data['labels'] as List?)?.cast<String>() ?? [],
  speakerNames: (data['speaker_names'] as Map?)?.cast<String, String>() ?? {},
  utteranceEdits: (data['utterance_edits'] as Map?)?.cast<String, String>() ?? {},
  speakerOverrides: (data['speaker_overrides'] as Map?)?.cast<String, String>() ?? {},
  generalNotes: data['general_notes'] as String? ?? '',
  transcriptNotes: ((data['transcript_notes'] as List?)?.cast<Map<String, dynamic>>() ?? [])
      .map((n) => NoteEntry(
        timestampMs: ((n['timestamp_s'] as num?) ?? 0.0).toDouble().round() * 1000,
        text: n['text'] as String? ?? '',
        title: n['title'] as String?,
      )).toList(),
);

List<NoteEntry> _notesFromResponse(Map<String, dynamic> data) =>
    ((data['notes_content'] as List?)?.cast<Map<String, dynamic>>() ?? [])
        .map((n) => NoteEntry(
          timestampMs: (n['timestamp_ms'] as num?)?.toInt() ?? 0,
          text: n['text'] as String? ?? '',
          title: n['title'] as String?,
        ))
        .toList();

List<TextSpan> _highlightSpans(String text, String query, TextStyle base, Color highlightColor) {
  if (query.isEmpty) return [TextSpan(text: text, style: base)];
  final spans = <TextSpan>[];
  final lower = text.toLowerCase();
  int start = 0;
  while (true) {
    final idx = lower.indexOf(query, start);
    if (idx == -1) {
      if (start < text.length) spans.add(TextSpan(text: text.substring(start), style: base));
      break;
    }
    if (idx > start) spans.add(TextSpan(text: text.substring(start, idx), style: base));
    spans.add(TextSpan(
      text: text.substring(idx, idx + query.length),
      style: base.copyWith(backgroundColor: highlightColor, color: Colors.black87),
    ));
    start = idx + query.length;
  }
  return spans;
}

// ── Types ─────────────────────────────────────────────────────────────────

enum _LoadState { loading, pending, error, done }

sealed class _TimelineItem { double get timestampS; }

class _UtteranceItem extends _TimelineItem {
  final _Utterance utterance;
  _UtteranceItem(this.utterance);
  @override double get timestampS => utterance.start;
}

class _NoteItem extends _TimelineItem {
  final double _ts;
  final String text;
  final String? title;
  final bool fromRecording;
  _NoteItem(this._ts, this.text, this.title, {required this.fromRecording});
  @override double get timestampS => _ts;
}

class _SectionBreak extends _TimelineItem {
  @override final double timestampS;
  _SectionBreak(this.timestampS);
}

class _Utterance {
  final String speaker;
  final double start;
  final double end;
  final String text;
  const _Utterance({required this.speaker, required this.start, required this.end, required this.text});
}

String _formatTime(double s) {
  final d = Duration(milliseconds: (s * 1000).round());
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$sec' : '$m:$sec';
}

// ── Speaker colors ────────────────────────────────────────────────────────

const _speakerColors = [
  Color(0xFF4FC3F7), Color(0xFFA5D6A7), Color(0xFFFFCC80),
  Color(0xFFCE93D8), Color(0xFFEF9A9A), Color(0xFF80DEEA),
];

Color _colorFor(String speaker) {
  final i = int.tryParse(speaker) ?? speaker.codeUnitAt(0);
  return _speakerColors[i % _speakerColors.length];
}

// ── Tiles ─────────────────────────────────────────────────────────────────

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(children: [
      const Expanded(child: Divider()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.fiber_manual_record, size: 5, color: Theme.of(context).colorScheme.outlineVariant),
      ),
      const Expanded(child: Divider()),
    ]),
  );
}

class _UtteranceTile extends StatelessWidget {
  final _Utterance utterance;
  final bool continuation;
  final String? effectiveSpeaker;
  final String? editedText;
  final String? speakerName;
  final String searchQuery;
  final bool isCurrentMatch;
  final VoidCallback onTapSpeaker;
  final VoidCallback onTapText;
  final VoidCallback onAddNote;

  const _UtteranceTile({
    required this.utterance,
    required this.onTapSpeaker,
    required this.onTapText,
    required this.onAddNote,
    this.continuation = false,
    this.effectiveSpeaker,
    this.editedText,
    this.speakerName,
    this.searchQuery = '',
    this.isCurrentMatch = false,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedSpeaker = effectiveSpeaker ?? utterance.speaker;
    final color = _colorFor(resolvedSpeaker);
    final label = speakerName ?? 'Hablante $resolvedSpeaker';
    final displayText = editedText ?? utterance.text;
    final isEdited = editedText != null;
    final baseStyle = Theme.of(context).textTheme.bodyMedium!;
    final highlightColor = isCurrentMatch ? Colors.orange.shade300 : Colors.yellow.shade300;

    return Padding(
      padding: EdgeInsets.only(bottom: continuation ? 3 : 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 32,
          child: continuation
              ? Text(_formatTime(utterance.start), textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: Theme.of(context).colorScheme.outline))
              : Column(children: [
                  GestureDetector(
                    onTap: onTapSpeaker,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: color.withValues(alpha: 0.2),
                      child: Text(
                        speakerName?.substring(0, 1).toUpperCase() ?? resolvedSpeaker,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(_formatTime(utterance.start),
                      style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: Theme.of(context).colorScheme.outline)),
                ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!continuation) ...[
              Row(children: [
                Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
                if (isEdited) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.edit, size: 10, color: Theme.of(context).colorScheme.outline),
                ],
              ]),
              const SizedBox(height: 2),
            ],
            GestureDetector(
              onTap: onTapText,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(2), topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12),
                  ),
                ),
                child: RichText(
                  text: TextSpan(children: _highlightSpans(displayText, searchQuery, baseStyle, highlightColor)),
                ),
              ),
            ),
          ]),
        ),
        IconButton(
          icon: Icon(Icons.add_comment_outlined, size: 16, color: Theme.of(context).colorScheme.outline),
          onPressed: onAddNote,
          tooltip: 'Añadir nota aquí',
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }
}

class _NoteTile extends StatelessWidget {
  final _NoteItem note;
  final String searchQuery;
  final bool isCurrentMatch;
  const _NoteTile({required this.note, this.searchQuery = '', this.isCurrentMatch = false});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodySmall!;
    final highlightColor = isCurrentMatch ? Colors.orange.shade300 : Colors.yellow.shade300;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Icon(note.fromRecording ? Icons.push_pin : Icons.sticky_note_2_outlined,
              size: 16, color: colors.primary),
          const SizedBox(height: 2),
          Text(_formatTime(note.timestampS),
              style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: colors.outline)),
        ]),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (note.title != null)
                Text(note.title!,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.primary)),
              RichText(
                text: TextSpan(children: _highlightSpans(note.text, searchQuery, baseStyle, highlightColor)),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
