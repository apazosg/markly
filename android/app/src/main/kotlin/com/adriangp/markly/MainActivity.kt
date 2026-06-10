package com.adriangp.markly

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.adriangp.markly/foreground"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val intent = Intent(this, RecordingService::class.java)
                when (call.method) {
                    "start" -> {
                        intent.action = RecordingService.ACTION_START
                        intent.putExtra(RecordingService.EXTRA_TEXT, call.argument<String>("text") ?: "Grabando…")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(null)
                    }
                    "update" -> {
                        intent.action = RecordingService.ACTION_UPDATE
                        intent.putExtra(RecordingService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        startService(intent)
                        result.success(null)
                    }
                    "stop" -> {
                        intent.action = RecordingService.ACTION_STOP
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
