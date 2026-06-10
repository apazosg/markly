import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'recording_controller.dart';
import 'models/note_entry.dart';
import '../auth/auth_service.dart';
import '../../shared/metadata_service.dart';

class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key});

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  final _controller = RecordingController();
  final _noteController = TextEditingController();
  final _noteFocus = FocusNode();
  final _notesScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onUpdate);
    _controller.loadDevices();
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_notesScroll.hasClients) {
        _notesScroll.animateTo(
          _notesScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _pinTimestamp() {
    _controller.pinTimestamp();
    _noteController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => _noteFocus.requestFocus());
  }

  void _submitNote() {
    final text = _noteController.text.trim();
    if (text.isEmpty) return;
    _controller.addNote(text);
    _noteController.clear();
  }

  void _cancelPin() {
    _controller.cancelPin();
    _noteController.clear();
  }

  Future<void> _startRecording() async {
    final error = await _controller.startRecording();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _stopRecording() async {
    final result = await _controller.stopRecording();
    if (result == null) return;
    final dir = p.dirname(result.audioPath);
    final meta = await MetadataService.read(dir);
    meta.durationMs = result.durationMs;
    await MetadataService.write(dir, meta);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Grabación guardada'), duration: Duration(seconds: 3)),
      );
    }
  }

  void _deleteNote(int index) {
    final deleted = _controller.notes[index];
    _controller.removeNote(index);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Nota eliminada'),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () => _controller.addNote(deleted.text),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _editNoteTitle(int index) async {
    final note = _controller.notes[index];
    final titleCtrl = TextEditingController(text: note.title ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Título de la nota'),
        content: TextField(
          controller: titleCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Título (opcional)'),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => Navigator.pop(ctx, titleCtrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, titleCtrl.text), child: const Text('Guardar')),
        ],
      ),
    );
    titleCtrl.dispose();
    if (result != null) _controller.updateNoteTitle(index, result);
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final isActive = state != RecordingState.idle;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Markly'),
        actions: [
          if (isActive)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: 'Detener y guardar',
              onPressed: _stopRecording,
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Cerrar sesión',
            onPressed: () => AuthService().signOut(),
          ),
        ],
      ),
      body: Column(
        children: [
          _TimerDisplay(controller: _controller),
          if (state == RecordingState.recording)
            _AmplitudeBar(level: _controller.amplitudeLevel),
          if (!isActive && Platform.isWindows && _controller.inputDevices.isNotEmpty)
            _DeviceSelector(controller: _controller),
          Expanded(
            child: _NotesList(
              notes: _controller.notes,
              scrollController: _notesScroll,
              canDelete: isActive,
              onDelete: _deleteNote,
              onTapNote: isActive ? _editNoteTitle : null,
            ),
          ),
          if (isActive)
            _NoteInput(
              controller: _noteController,
              focus: _noteFocus,
              pendingTimestampMs: _controller.pendingTimestampMs,
              onPin: _pinTimestamp,
              onSubmit: _submitNote,
              onCancel: _cancelPin,
            ),
          _ControlBar(
            state: state,
            onStart: _startRecording,
            onPause: _controller.pauseRecording,
            onResume: _controller.resumeRecording,
            onStop: _stopRecording,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    _noteController.dispose();
    _noteFocus.dispose();
    _notesScroll.dispose();
    super.dispose();
  }
}

// ── Timer + status ──────────────────────────────────────────────────────────

class _TimerDisplay extends StatelessWidget {
  final RecordingController controller;
  const _TimerDisplay({required this.controller});

  static String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = controller.state;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Text(_format(controller.elapsed), style: theme.textTheme.displayLarge?.copyWith(letterSpacing: 4)),
          const SizedBox(height: 10),
          _StatusBadge(state: state),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final RecordingState state;
  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (state) {
      RecordingState.recording => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: theme.colorScheme.error, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text('GRABANDO', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.error)),
          ],
        ),
      RecordingState.paused => Text('EN PAUSA', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.tertiary)),
      RecordingState.idle => Text('LISTO', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
    };
  }
}

// ── Amplitude bar ───────────────────────────────────────────────────────────

class _AmplitudeBar extends StatelessWidget {
  final double level;
  const _AmplitudeBar({required this.level});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: level,
          minHeight: 3,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

// ── Device selector (Windows only) ─────────────────────────────────────────

class _DeviceSelector extends StatelessWidget {
  final RecordingController controller;
  const _DeviceSelector({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          const Icon(Icons.settings_input_component, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<InputDevice>(
              isExpanded: true,
              value: controller.selectedDevice,
              items: controller.inputDevices
                  .map((d) => DropdownMenuItem(value: d, child: Text(d.label, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (d) { if (d != null) controller.selectDevice(d); },
            ),
          ),
          Tooltip(
            message: 'Para audio del sistema (Teams, Zoom…)\nactiva "Stereo Mix" en Sonido → Grabar\no instala VB-Audio Cable (gratuito).',
            preferBelow: false,
            child: Icon(Icons.help_outline, size: 18, color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

// ── Notes list ──────────────────────────────────────────────────────────────

class _NotesList extends StatelessWidget {
  final List<NoteEntry> notes;
  final ScrollController scrollController;
  final bool canDelete;
  final void Function(int index) onDelete;
  final void Function(int index)? onTapNote;

  const _NotesList({
    required this.notes,
    required this.scrollController,
    required this.canDelete,
    required this.onDelete,
    this.onTapNote,
  });

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Las notas que añadas aparecerán aquí\ncon el timestamp de la grabación.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: notes.length,
      itemBuilder: (context, i) {
        final tile = _NoteTile(note: notes[i], onTap: onTapNote != null ? () => onTapNote!(i) : null);
        if (!canDelete) return tile;
        return Dismissible(
          key: ValueKey('${notes[i].timestampMs}_${notes[i].text}'),
          direction: DismissDirection.endToStart,
          onDismissed: (_) => onDelete(i),
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.onErrorContainer),
          ),
          child: tile,
        );
      },
    );
  }
}

class _NoteTile extends StatelessWidget {
  final NoteEntry note;
  final VoidCallback? onTap;
  const _NoteTile({required this.note, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                note.formattedTimestamp,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (note.title != null)
                    Text(note.title!, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    note.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: note.title != null ? theme.colorScheme.onSurface.withValues(alpha: 0.75) : null,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.edit_outlined, size: 14, color: theme.colorScheme.outline.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}

// ── Note input ──────────────────────────────────────────────────────────────

class _NoteInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final int? pendingTimestampMs;
  final VoidCallback onPin;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  const _NoteInput({
    required this.controller,
    required this.focus,
    required this.pendingTimestampMs,
    required this.onPin,
    required this.onSubmit,
    required this.onCancel,
  });

  String _format(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPending = pendingTimestampMs != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.15))),
      ),
      child: hasPending ? _buildTextEntry(context, theme) : _buildPinButton(theme),
    );
  }

  // Estado 1: botón para fijar el timestamp
  Widget _buildPinButton(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.push_pin_outlined, size: 18),
        label: const Text('Añadir nota'),
        onPressed: onPin,
      ),
    );
  }

  // Estado 2: timestamp fijado, campo de texto listo para escribir
  Widget _buildTextEntry(BuildContext context, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Timestamp badge (locked)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            _format(pendingTimestampMs!),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Escribe la nota…',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSubmit(),
            maxLines: null,
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          icon: const Icon(Icons.check, size: 20),
          onPressed: onSubmit,
          tooltip: 'Guardar nota',
        ),
        IconButton(
          icon: Icon(Icons.close, size: 20, color: theme.colorScheme.outline),
          onPressed: onCancel,
          tooltip: 'Cancelar',
        ),
      ],
    );
  }
}

// ── Controls ────────────────────────────────────────────────────────────────

class _ControlBar extends StatelessWidget {
  final RecordingState state;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;

  const _ControlBar({
    required this.state,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: switch (state) {
        RecordingState.idle => SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.mic),
              label: const Text('Iniciar grabación'),
              style: FilledButton.styleFrom(backgroundColor: errorColor, padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: onStart,
            ),
          ),
        RecordingState.recording => Row(
            children: [
              Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.pause), label: const Text('Pausar'), onPressed: onPause)),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text('Detener'),
                  style: FilledButton.styleFrom(backgroundColor: errorColor),
                  onPressed: onStop,
                ),
              ),
            ],
          ),
        RecordingState.paused => Row(
            children: [
              Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('Continuar'), onPressed: onResume)),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text('Detener'),
                  style: FilledButton.styleFrom(backgroundColor: errorColor),
                  onPressed: onStop,
                ),
              ),
            ],
          ),
      },
    );
  }
}
