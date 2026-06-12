import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../shared/api_service.dart';
import '../../shared/reminder_service.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  List<_Task> _tasks = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ApiService().listTasks();
      if (mounted) {
        setState(() {
          _tasks = data.map(_Task.fromJson).toList();
          _loading = false;
        });
        ReminderService.instance.evaluate(data);
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'No se pudieron cargar las tareas'; });
    }
  }

  List<_Task> _byStatus(String status) =>
      _tasks.where((t) => t.status == status).toList();

  Future<void> _patch(_Task task, Map<String, dynamic> patch) async {
    try {
      final updated = await ApiService().updateTask(task.id, patch);
      setState(() {
        final i = _tasks.indexWhere((t) => t.id == task.id);
        if (i >= 0) _tasks[i] = _Task.fromJson(updated);
      });
      // Editar una fecha ya vencida/hoy debe poder avisar al momento.
      if (patch.containsKey('due_date')) ReminderService.instance.syncFromApi();
    } catch (_) {
      _snack('No se pudo actualizar la tarea');
    }
  }

  Future<void> _editDate(_Task task) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: task.dueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: 'Fecha límite',
    );
    if (picked == null) return;
    await _patch(task, {
      'due_date': DateTime(picked.year, picked.month, picked.day).toIso8601String(),
    });
  }

  Future<void> _delete(_Task task) async {
    setState(() => _tasks.removeWhere((t) => t.id == task.id));
    try {
      await ApiService().deleteTask(task.id);
    } catch (_) {
      _snack('No se pudo eliminar la tarea');
      _load();
    }
  }

  Future<void> _addManual() async {
    final text = await _promptText();
    if (text == null || text.trim().isEmpty) return;
    try {
      final created = await ApiService().createTask({'text': text.trim(), 'status': 'pending'});
      setState(() => _tasks.add(_Task.fromJson(created)));
    } catch (_) {
      _snack('No se pudo crear la tarea');
    }
  }

  Future<String?> _promptText({String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva tarea'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Ej: Enviar el informe el viernes'),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Crear')),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final suggested = _byStatus('suggested');
    final pending = _byStatus('pending')
      ..sort((a, b) {
        // Pendientes por fecha ascendente; las sin fecha, al final.
        if (a.dueDate == null && b.dueDate == null) return 0;
        if (a.dueDate == null) return 1;
        if (b.dueDate == null) return -1;
        return a.dueDate!.compareTo(b.dueDate!);
      });
    final done = _byStatus('done');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tareas'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addManual,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _tasks.isEmpty
                  ? const _EmptyState()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                        children: [
                          if (suggested.isNotEmpty)
                            _Section(
                              title: 'Sugerencias',
                              subtitle: 'Detectadas en reuniones y chat. Confírmalas o descártalas.',
                              children: suggested
                                  .map((t) => _SuggestionCard(
                                        task: t,
                                        onConfirm: () => _patch(t, {'status': 'pending'}),
                                        onDismiss: () => _delete(t),
                                      ))
                                  .toList(),
                            ),
                          if (pending.isNotEmpty)
                            _Section(
                              title: 'Pendientes',
                              children: pending
                                  .map((t) => _TaskTile(
                                        task: t,
                                        onToggle: () => _patch(t, {'status': 'done'}),
                                        onDelete: () => _delete(t),
                                        onSetDate: () => _editDate(t),
                                        onClearDate: t.dueDate != null
                                            ? () => _patch(t, {'due_date': null})
                                            : null,
                                      ))
                                  .toList(),
                            ),
                          if (done.isNotEmpty)
                            _Section(
                              title: 'Hechas',
                              children: done
                                  .map((t) => _TaskTile(
                                        task: t,
                                        onToggle: () => _patch(t, {'status': 'pending'}),
                                        onDelete: () => _delete(t),
                                      ))
                                  .toList(),
                            ),
                        ],
                      ),
                    ),
    );
  }
}

// ── Data ─────────────────────────────────────────────────────────────────────

class _Task {
  final String id;
  final String text;
  final String status;
  final String? assignee;
  final DateTime? dueDate;
  final String? priority;
  _Task({
    required this.id,
    required this.text,
    required this.status,
    this.assignee,
    this.dueDate,
    this.priority,
  });

  factory _Task.fromJson(Map<String, dynamic> j) => _Task(
        id: j['id'] as String,
        text: j['text'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
        assignee: j['assignee'] as String?,
        dueDate: j['due_date'] != null ? DateTime.tryParse(j['due_date'] as String) : null,
        priority: j['priority'] as String?,
      );
}

// ── Widgets ──────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _Section({required this.title, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(subtitle!, style: TextStyle(fontSize: 12, color: colors.outline)),
          ),
        ...children,
      ],
    );
  }
}

class _TaskMeta extends StatelessWidget {
  final _Task task;
  const _TaskMeta({required this.task});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bits = <String>[
      if (task.assignee != null) task.assignee!,
      if (task.dueDate != null) DateFormat('d MMM', 'es').format(task.dueDate!),
      if (task.priority != null) task.priority!,
    ];
    if (bits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(bits.join(' · '), style: TextStyle(fontSize: 12, color: colors.outline)),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final _Task task;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;
  const _SuggestionCard({required this.task, required this.onConfirm, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.lightbulb_outline, size: 20),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.text),
                  _TaskMeta(task: task),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.check_circle, color: colors.primary),
              tooltip: 'Confirmar',
              onPressed: onConfirm,
            ),
            IconButton(
              icon: Icon(Icons.cancel_outlined, color: colors.outline),
              tooltip: 'Descartar',
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final _Task task;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback? onSetDate;
  final VoidCallback? onClearDate;
  const _TaskTile({
    required this.task,
    required this.onToggle,
    required this.onDelete,
    this.onSetDate,
    this.onClearDate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDone = task.status == 'done';
    return Dismissible(
      key: ValueKey(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: colors.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        dense: true,
        leading: Checkbox(value: isDone, onChanged: (_) => onToggle()),
        title: Text(
          task.text,
          style: TextStyle(
            decoration: isDone ? TextDecoration.lineThrough : null,
            color: isDone ? colors.outline : null,
          ),
        ),
        subtitle: isDone ? null : _TaskMeta(task: task),
        trailing: onSetDate == null
            ? null
            : PopupMenuButton<String>(
                icon: Icon(Icons.event_outlined, size: 20,
                    color: task.dueDate != null ? colors.primary : colors.outline),
                tooltip: 'Fecha límite',
                onSelected: (v) => v == 'set' ? onSetDate!() : onClearDate?.call(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'set',
                      child: Text(task.dueDate == null ? 'Añadir fecha' : 'Cambiar fecha')),
                  if (task.dueDate != null && onClearDate != null)
                    const PopupMenuItem(value: 'clear', child: Text('Quitar fecha')),
                ],
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.checklist, size: 48, color: colors.primary),
          const SizedBox(height: 16),
          Text('No hay tareas todavía', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Las tareas detectadas en tus reuniones y en el chat aparecerán aquí para que las confirmes.',
            style: TextStyle(color: colors.outline, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}
