package com.mangaflow.mangaflow

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Volume buttons turn pages in the reader while enabled from Dart (mangaflow/volume_keys).
 * FragmentActivity: required by local_auth (fingerprint / face unlock).
 */
class MainActivity : FlutterFragmentActivity() {
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
                        LibraryWidgetProvider.refresh(applicationContext)
                        result.success(null)
                    }
                    "pin" -> result.success(pinWidget(call.arguments as? String ?: "continue"))
                    "initialRoute" -> {
                        result.success(pendingRoute)
                        pendingRoute = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/privacy").setMethodCallHandler { call, result ->
            if (call.method == "hideInRecents") {
                hideInRecents(call.arguments as? Boolean ?: false)
                result.success(null)
            } else {
                result.notImplemented()
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

    /** Android 13+: blank preview in recents, screenshots still allowed. Older: FLAG_SECURE. */
    private fun hideInRecents(hide: Boolean) {
        if (Build.VERSION.SDK_INT >= 33) {
            setRecentsScreenshotEnabled(!hide)
        } else if (hide) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    /** «Добавить на рабочий стол»: the launcher shows its own confirmation. */
    private fun pinWidget(kind: String): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        val manager = getSystemService(AppWidgetManager::class.java) ?: return false
        if (!manager.isRequestPinAppWidgetSupported) return false
        val cls = if (kind == "library") LibraryWidgetProvider::class.java else ContinueWidgetProvider::class.java
        return manager.requestPinAppWidget(ComponentName(this, cls), null, null)
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
