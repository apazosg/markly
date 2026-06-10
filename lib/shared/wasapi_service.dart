import 'dart:io';
import 'package:flutter/services.dart';

// Captura WASAPI unificada en Windows (micro + audio del sistema vía loopback),
// implementada en el runner nativo. Escribe un único WAV mono ya mezclado.
class WasapiService {
  static const _channel = MethodChannel('com.adriangp.markly/wasapi');

  static bool get isSupported => Platform.isWindows;

  // Arranca la captura hacia [path]. [captureSystem] añade el audio del
  // sistema. Devuelve true si arrancó.
  static Future<bool> start(String path, {required bool captureSystem}) async {
    if (!isSupported) return false;
    final ok = await _channel.invokeMethod<bool>(
      'start',
      {'path': path, 'captureSystem': captureSystem},
    );
    return ok ?? false;
  }

  static Future<void> stop() async {
    if (!isSupported) return;
    await _channel.invokeMethod('stop');
  }

  static Future<void> pause() async {
    if (!isSupported) return;
    await _channel.invokeMethod('pause');
  }

  static Future<void> resume() async {
    if (!isSupported) return;
    await _channel.invokeMethod('resume');
  }

  // Nivel de pico normalizado [0,1] para el medidor.
  static Future<double> amplitude() async {
    if (!isSupported) return 0;
    final v = await _channel.invokeMethod<double>('amplitude');
    return v ?? 0;
  }
}
