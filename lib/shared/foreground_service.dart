import 'dart:io';
import 'package:flutter/services.dart';

class ForegroundService {
  static const _channel = MethodChannel('com.adriangp.markly/foreground');

  static Future<void> start(String text) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('start', {'text': text});
  }

  static Future<void> update(String text) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('update', {'text': text});
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('stop');
  }
}
