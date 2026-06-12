import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// Avisos de vencimiento de tareas mientras la app está abierta.
///
/// No programa alarmas a nivel de SO: cada vez que se evalúa (al arrancar, por
/// timer o tras editar tareas) comprueba qué avisos ya tocan (víspera 12:00 y
/// la mañana del vencimiento 09:00) y avisa de los que aún no se han avisado.
/// Si la app estaba cerrada a esa hora, el aviso salta al reabrir (catch-up),
/// una sola vez por tarea/fecha/momento.
///
/// Canal según plataforma: en Android, notificación de sistema; en el resto
/// (Windows…), un SnackBar in-app vía [messengerKey].
class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  /// Se asigna a `MaterialApp.scaffoldMessengerKey` para poder mostrar avisos
  /// in-app desde el servicio (plataformas sin notificación de sistema).
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static const _channelId = 'task_reminders';
  static const _prefsKey = 'reminded_keys';

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _systemReady = false;
  bool _initDone = false;

  bool get _useSystem => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    if (!_useSystem) return; // Windows/otros: solo in-app, sin plugin nativo.
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _systemReady = true;
    } catch (_) {
      _systemReady = false;
    }
  }

  Future<void> syncFromApi() async {
    try {
      await evaluate(await ApiService().listTasks());
    } catch (_) {}
  }

  Future<void> evaluate(List<Map<String, dynamic>> tasks) async {
    await init();

    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final reminded = prefs.getStringList(_prefsKey)?.toSet() ?? <String>{};
    final inApp = <String>[];
    var changed = false;

    for (final t in tasks) {
      if (t['status'] != 'pending') continue;
      final raw = t['due_date'] as String?;
      if (raw == null) continue;
      final due = DateTime.tryParse(raw);
      if (due == null) continue;

      final day = DateTime(due.year, due.month, due.day);
      final dayIso = '${day.year}-${day.month}-${day.day}';
      final moments = <String, DateTime>{
        'eve': day.subtract(const Duration(days: 1)).add(const Duration(hours: 12)),
        'morn': day.add(const Duration(hours: 9)),
      };

      for (final entry in moments.entries) {
        if (now.isBefore(entry.value)) continue;
        final key = '${t['id']}|${entry.key}|$dayIso';
        if (reminded.contains(key)) continue;

        final body = entry.key == 'eve'
            ? 'Vence mañana: ${t['text'] ?? 'Tarea'}'
            : 'Vence hoy: ${t['text'] ?? 'Tarea'}';
        // Android/iOS: toast de sistema (queda en la bandeja). Además, en todas
        // las plataformas, aviso in-app mientras se usa la app.
        if (_useSystem && _systemReady) await _showSystem(key, body);
        inApp.add(body);
        reminded.add(key);
        changed = true;
      }
    }

    if (changed) await prefs.setStringList(_prefsKey, reminded.toList());
    if (inApp.isNotEmpty) _showInApp(inApp);
  }

  Future<void> _showSystem(String key, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Recordatorios de tareas',
        channelDescription: 'Avisos de vencimiento de tareas',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    try {
      await _plugin.show(key.hashCode & 0x7fffffff, 'Tarea por vencer', body, details);
    } catch (_) {}
  }

  void _showInApp(List<String> bodies) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    final text = bodies.length == 1
        ? bodies.first
        : '${bodies.length} tareas próximas a vencer';
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 6),
      ));
  }
}
