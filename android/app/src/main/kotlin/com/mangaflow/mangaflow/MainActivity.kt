package com.mangaflow.mangaflow

import android.content.Intent
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Volume buttons turn pages in the reader while enabled from Dart (mangaflow/volume_keys). */
class MainActivity : FlutterActivity() {
    private var volumeKeys = false
    private var channel: MethodChannel? = null
    private var widgetChannel: MethodChannel? = null
    private var pendingRoute: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingRoute = intent?.getStringExtra(ContinueWidgetProvider.EXTRA_ROUTE)
        widgetChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/widget").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        ContinueWidgetProvider.refresh(applicationContext)
                        result.success(null)
                    }
                    "initialRoute" -> {
                        result.success(pendingRoute)
                        pendingRoute = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/volume_keys").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "setEnabled") {
                    volumeKeys = call.arguments as? Boolean ?: false
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(ContinueWidgetProvider.EXTRA_ROUTE)?.let { widgetChannel?.invokeMethod("open", it) }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode
        if (volumeKeys && (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                channel?.invokeMethod("key", if (code == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down")
            }
            return true // swallow: no system volume change / slider while reading
        }
        return super.dispatchKeyEvent(event)
    }
}
