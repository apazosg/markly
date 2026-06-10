import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../shared/api_service.dart';
import '../history/transcript_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messages = <_ChatMsg>[];
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();

  bool _sending = false;
  bool _recording = false;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  List<Map<String, String>> get _history =>
      _messages.map((m) => {'role': m.role, 'content': m.content}).toList();

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendText() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    _inputCtrl.clear();
    setState(() {
      _messages.add(_ChatMsg(role: 'user', content: text));
      _sending = true;
    });
    _scrollToBottom();
    try {
      final data = await ApiService().chatText(_history);
      _appendAnswer(data);
    } catch (e) {
      _appendError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleVoice() async {
    if (_sending) return;
    if (_recording) {
      await _stopAndSendVoice();
      return;
    }
    if (!await _recorder.hasPermission()) {
      _showSnack('Permiso de micrófono denegado');
      return;
    }
    final dir = await getTemporaryDirectory();
    // Windows no soporta el encoder AAC del paquete record; usa WAV (PCM).
    final isWav = Platform.isWindows;
    final path = p.join(dir.path, 'chat_query.${isWav ? 'wav' : 'm4a'}');
    await _recorder.start(
      RecordConfig(
        encoder: isWav ? AudioEncoder.wav : AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    setState(() => _recording = true);
  }

  Future<void> _stopAndSendVoice() async {
    final path = await _recorder.stop();
    setState(() => _recording = false);
    if (path == null) return;
    setState(() => _sending = true);
    try {
      final data = await ApiService().chatAudio(path, _history);
      final query = data['query'] as String? ?? '';
      if (query.isNotEmpty) {
        setState(() => _messages.add(_ChatMsg(role: 'user', content: query)));
        _scrollToBottom();
      }
      _appendAnswer(data);
    } catch (e) {
      _appendError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _appendAnswer(Map<String, dynamic> data) {
    if (!mounted) return;
    final sources = ((data['sources'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map(_Source.fromJson)
        .toList();
    final tasks = ((data['suggested_tasks'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map(_SuggestedTask.fromJson)
        .toList();
    final actions = ((data['suggested_actions'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map(_SuggestedAction.fromJson)
        .where((a) => a.serverId.isNotEmpty)
        .toList();
    setState(() => _messages.add(_ChatMsg(
          role: 'assistant',
          content: data['answer'] as String? ?? '',
          sources: sources,
          tasks: tasks,
          actions: actions,
        )));
    _scrollToBottom();
  }

  Future<void> _addTask(_SuggestedTask task) async {
    try {
      await ApiService().createTask({
        'text': task.text,
        'status': 'pending',
        'source_type': 'chat',
        if (task.assignee != null) 'assignee': task.assignee,
        if (task.dueDate != null) 'due_date': task.dueDate,
        if (task.priority != null) 'priority': task.priority,
      });
      setState(() => task.added = true);
      _showSnack('Tarea añadida a Tareas');
    } catch (_) {
      _showSnack('No se pudo añadir la tarea');
    }
  }

  Future<void> _applyAction(_SuggestedAction action) async {
    try {
      await ApiService().updateMetadata(action.serverId, action.toPatch());
      setState(() => action.applied = true);
      _showSnack('Reunión actualizada');
    } catch (_) {
      _showSnack('No se pudo aplicar el cambio');
    }
  }

  void _dismissAction(_SuggestedAction action) {
    setState(() => action.dismissed = true);
  }

  void _appendError(Object e) {
    final msg = e.toString();
    final isQuota = msg.contains('402') || msg.contains('Límite mensual');
    setState(() => _messages.add(_ChatMsg(
          role: 'assistant',
          content: isQuota
              ? 'Has alcanzado el límite mensual de créditos. Revisa tu cuenta.'
              : 'No pude responder ahora mismo. Inténtalo de nuevo.',
        )));
    _scrollToBottom();
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _openSource(_Source s) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => TranscriptPage(serverId: s.id, sessionLabel: s.title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Asistente')),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: _messages.length + (_sending ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _messages.length) return const _TypingBubble();
                      return _MessageBubble(
                        message: _messages[i],
                        onSourceTap: _openSource,
                        onAddTask: _addTask,
                        onApplyAction: _applyAction,
                        onDismissAction: _dismissAction,
                      );
                    },
                  ),
          ),
          _Composer(
            controller: _inputCtrl,
            recording: _recording,
            sending: _sending,
            onSend: _sendText,
            onVoice: _toggleVoice,
          ),
        ],
      ),
    );
  }
}

// ── Data ─────────────────────────────────────────────────────────────────────

class _ChatMsg {
  final String role;
  final String content;
  final List<_Source> sources;
  final List<_SuggestedTask> tasks;
  final List<_SuggestedAction> actions;
  _ChatMsg({
    required this.role,
    required this.content,
    this.sources = const [],
    this.tasks = const [],
    this.actions = const [],
  });
}

class _SuggestedAction {
  final String serverId;
  final String sessionTitle;
  final String description;
  final String? title;
  final List<String>? labels;
  final Map<String, String>? speakerNames;
  final String? generalNotes;
  bool applied = false;
  bool dismissed = false;
  _SuggestedAction({
    required this.serverId,
    required this.sessionTitle,
    required this.description,
    this.title,
    this.labels,
    this.speakerNames,
    this.generalNotes,
  });

  factory _SuggestedAction.fromJson(Map<String, dynamic> j) => _SuggestedAction(
        serverId: j['server_id'] as String? ?? '',
        sessionTitle: j['session_title'] as String? ?? 'Reunión',
        description: j['description'] as String? ?? 'Modificar reunión',
        title: j['title'] as String?,
        labels: (j['labels'] as List?)?.map((e) => e.toString()).toList(),
        speakerNames: (j['speaker_names'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), v.toString())),
        generalNotes: j['general_notes'] as String?,
      );

  Map<String, dynamic> toPatch() => {
        if (title != null) 'title': title,
        if (labels != null) 'labels': labels,
        if (speakerNames != null) 'speaker_names': speakerNames,
        if (generalNotes != null) 'general_notes': generalNotes,
      };
}

class _SuggestedTask {
  final String text;
  final String? assignee;
  final String? dueDate;
  final String? priority;
  bool added = false;
  _SuggestedTask({required this.text, this.assignee, this.dueDate, this.priority});

  factory _SuggestedTask.fromJson(Map<String, dynamic> j) => _SuggestedTask(
        text: j['text'] as String? ?? '',
        assignee: j['assignee'] as String?,
        dueDate: j['due_date'] as String?,
        priority: j['priority'] as String?,
      );
}

class _Source {
  final String id;
  final String sessionId;
  final String title;
  final String createdAt;
  _Source({required this.id, required this.sessionId, required this.title, required this.createdAt});

  factory _Source.fromJson(Map<String, dynamic> j) => _Source(
        id: j['id'] as String,
        sessionId: j['session_id'] as String? ?? '',
        title: j['title'] as String? ?? 'Reunión',
        createdAt: j['created_at'] as String? ?? '',
      );
}

// ── Widgets ──────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome, size: 48, color: colors.primary),
          const SizedBox(height: 16),
          Text('Pregunta sobre tus reuniones',
              style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            '"¿De qué hablamos en el último one to one?", "¿Cuándo se decidió migrar a Postgres?"',
            style: TextStyle(color: colors.outline, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final _ChatMsg message;
  final void Function(_Source) onSourceTap;
  final void Function(_SuggestedTask) onAddTask;
  final void Function(_SuggestedAction) onApplyAction;
  final void Function(_SuggestedAction) onDismissAction;
  const _MessageBubble({
    required this.message,
    required this.onSourceTap,
    required this.onAddTask,
    required this.onApplyAction,
    required this.onDismissAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? colors.primary : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.content,
                style: TextStyle(color: isUser ? colors.onPrimary : colors.onSurface)),
            if (message.sources.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: message.sources
                    .map((s) => ActionChip(
                          avatar: const Icon(Icons.article_outlined, size: 16),
                          label: Text(s.title, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onSourceTap(s),
                        ))
                    .toList(),
              ),
            ],
            if (message.tasks.isNotEmpty) ...[
              const Divider(height: 16),
              Text('Tareas detectadas',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.outline)),
              const SizedBox(height: 4),
              ...message.tasks.map((t) => _TaskSuggestionRow(
                    task: t,
                    onAdd: () => onAddTask(t),
                  )),
            ],
            if (message.actions.isNotEmpty) ...[
              const Divider(height: 16),
              Text('Cambios propuestos',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.outline)),
              const SizedBox(height: 6),
              ...message.actions.map((a) => _ActionConfirmCard(
                    action: a,
                    onApply: () => onApplyAction(a),
                    onDismiss: () => onDismissAction(a),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionConfirmCard extends StatelessWidget {
  final _SuggestedAction action;
  final VoidCallback onApply;
  final VoidCallback onDismiss;
  const _ActionConfirmCard({
    required this.action,
    required this.onApply,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final resolved = action.applied || action.dismissed;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.edit_note, size: 16, color: colors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(action.sessionTitle,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 4),
          Text(action.description, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          if (action.applied)
            Row(children: [
              Icon(Icons.check_circle, size: 16, color: colors.primary),
              const SizedBox(width: 4),
              Text('Aplicado', style: TextStyle(fontSize: 12, color: colors.primary)),
            ])
          else if (action.dismissed)
            Text('Descartado', style: TextStyle(fontSize: 12, color: colors.outline))
          else
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: resolved ? null : onDismiss,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Descartar'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: resolved ? null : onApply,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('Confirmar'),
              ),
            ]),
        ],
      ),
    );
  }
}

class _TaskSuggestionRow extends StatelessWidget {
  final _SuggestedTask task;
  final VoidCallback onAdd;
  const _TaskSuggestionRow({required this.task, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(Icons.task_alt, size: 16, color: colors.primary),
        const SizedBox(width: 6),
        Expanded(child: Text(task.text, style: const TextStyle(fontSize: 13))),
        task.added
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.check, size: 18, color: colors.primary),
              )
            : TextButton(
                onPressed: onAdd,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Añadir'),
              ),
      ]),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool recording;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onVoice;
  const _Composer({
    required this.controller,
    required this.recording,
    required this.sending,
    required this.onSend,
    required this.onVoice,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !recording,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: recording ? 'Grabando pregunta…' : 'Escribe tu pregunta…',
                isDense: true,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          IconButton(
            icon: Icon(recording ? Icons.stop_circle : Icons.mic,
                color: recording ? colors.error : colors.primary),
            tooltip: recording ? 'Enviar pregunta de voz' : 'Preguntar por voz',
            onPressed: sending ? null : onVoice,
          ),
          IconButton.filled(
            icon: const Icon(Icons.send),
            onPressed: sending || recording ? null : onSend,
          ),
        ]),
      ),
    );
  }
}
