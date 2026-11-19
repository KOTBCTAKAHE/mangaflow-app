package com.mangaflow.mangaflow

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Volume buttons turn pages in the reader while enabled from Dart (mangaflow/volume_keys). */
class MainActivity : FlutterActivity() {
    private var volumeKeys = false
    private var channel: MethodChannel? = null
    private var widgetChannel: MethodChannel? = null
    private var pendingRoute: String? = null
    private var transferChannel: MethodChannel? = null
    @Volatile private var pendingFile: String? = null

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
        transferChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/transfer").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "pending") {
                    result.success(pendingFile)
                    pendingFile = null
                } else {
                    result.notImplemented()
                }
            }
        }
        handleIncoming(intent)
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
        handleIncoming(intent)
    }

    /** A .cbz/.zip opened with (VIEW) or shared to (SEND) MangaFlow: copy it into the cache for Dart. */
    private fun handleIncoming(incoming: Intent?) {
        val intent = incoming ?: return
        val uri: Uri = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            else -> null
        } ?: return
        intent.action = null // don't import twice on configuration changes
        Thread {
            try {
                var name = "chapters.cbz"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
                }
                val mime = intent.type ?: contentResolver.getType(uri) ?: ""
                if (mime.startsWith("image/") && !Regex("\\.(jpe?g|png|webp|gif|heic|avif)$", RegexOption.IGNORE_CASE).containsMatchIn(name)) {
                    name = "shared." + mime.substringAfter('/').replace("jpeg", "jpg").substringBefore(';')
                }
                val dir = File(cacheDir, "incoming").apply { mkdirs() }
                dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000L }?.forEach { it.delete() }
                val safe = name.replace(Regex("[^\\p{L}\\p{N}._ ()-]"), "_").take(120)
                val out = File(dir, "${System.currentTimeMillis()}_$safe")
                val input = if (uri.scheme == "file") File(uri.path ?: return@Thread).inputStream() else contentResolver.openInputStream(uri)
                input?.use { i -> out.outputStream().use { o -> i.copyTo(o, 1 shl 16) } } ?: return@Thread
                pendingFile = out.path
                runOnUiThread { transferChannel?.invokeMethod("incoming", null) }
            } catch (_: Exception) {
                // unreadable stream: nothing to import
            }
        }.start()
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
