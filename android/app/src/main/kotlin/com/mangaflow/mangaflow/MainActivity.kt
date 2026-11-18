package com.mangaflow.mangaflow

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.mangaflow.mangaflow.upscale.UpscalePlugin

/** Volume buttons turn pages in the reader while enabled from Dart (mangaflow/volume_keys). */
class MainActivity : FlutterActivity() {
    private var volumeKeys = false
    private var channel: MethodChannel? = null
    private var upscale: UpscalePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        upscale = UpscalePlugin(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
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
