package com.mangaflow.mangaflow

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.view.WindowManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Volume buttons turn pages in the reader while enabled from Dart (mangaflow/volume_keys). */
/** FragmentActivity: required by local_auth (fingerprint / face unlock). */
class MainActivity : FlutterFragmentActivity() {
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/ota").setMethodCallHandler { call, result ->
            fun bg(work: () -> Any?) = Thread {
                try {
                    val v = work()
                    runOnUiThread { result.success(v) }
                } catch (e: Throwable) {
                    runOnUiThread { result.error("ota_failed", e.message ?: e.javaClass.simpleName, null) }
                }
            }.start()
            when (call.method) {
                "installedApk" -> bg {
                    val f = File(applicationInfo.sourceDir)
                    mapOf("path" to f.absolutePath, "size" to f.length(), "sha256" to OtaUpdater.sha256(f))
                }
                "apply" -> bg {
                    val out = File(call.argument<String>("out")!!)
                    OtaUpdater.apply(File(applicationInfo.sourceDir), File(call.argument<String>("patch")!!), out)
                    OtaUpdater.sha256(out)
                }
                "sha256" -> bg { OtaUpdater.sha256(File(call.argument<String>("path")!!)) }
                "install" -> result.success(installApk(File(call.argument<String>("path")!!)))
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/gallery").setMethodCallHandler { call, result ->
            when (call.method) {
                "needsPermission" -> result.success(Build.VERSION.SDK_INT < 29 &&
                    checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != android.content.pm.PackageManager.PERMISSION_GRANTED)
                "requestPermission" -> {
                    if (Build.VERSION.SDK_INT < 29) {
                        requestPermissions(arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE), 7301)
                    }
                    result.success(null)
                }
                "save" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "MangaFlow"
                    val mime = call.argument<String>("mime") ?: "image/jpeg"
                    if (path == null) {
                        result.error("bad_args", "path", null)
                    } else {
                        Thread {
                            try {
                                val uri = saveToGallery(File(path), name, mime)
                                runOnUiThread { result.success(uri) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("save_failed", e.message ?: e.javaClass.simpleName, null) }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mangaflow/pdf").setMethodCallHandler { call, result ->
            if (call.method != "render") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val out = call.argument<String>("out")
            val width = call.argument<Int>("width") ?: 1400
            if (path == null || out == null) {
                result.error("bad_args", "path/out", null)
                return@setMethodCallHandler
            }
            Thread {
                try {
                    val n = renderPdf(File(path), File(out), width)
                    runOnUiThread { result.success(n) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("pdf", e.message ?: e.javaClass.simpleName, null) }
                }
            }.start()
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(ContinueWidgetProvider.EXTRA_ROUTE)?.let { widgetChannel?.invokeMethod("open", it) }
        handleIncoming(intent)
    }

    /** "started" | "permission" (the user must allow installs from MangaFlow first). */
    private fun installApk(apk: File): String {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return "permission"
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.ota", apk)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        return "started"
    }

    /** Pictures/MangaFlow. Android 10+: MediaStore (no permission); older: the public folder + media scan. */
    private fun saveToGallery(src: File, name: String, mime: String): String {
        val ext = when (mime) { "image/png" -> "png"; "image/webp" -> "webp"; else -> "jpg" }
        if (Build.VERSION.SDK_INT >= 29) {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "$name.$ext")
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, mime)
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/MangaFlow")
                put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                    ?: throw IllegalStateException("no output stream")
                values.clear()
                values.put(android.provider.MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_PICTURES), "MangaFlow")
        dir.mkdirs()
        var out = File(dir, "$name.$ext")
        var n = 2
        while (out.exists()) out = File(dir, "$name ($n).$ext").also { n++ }
        src.copyTo(out)
        android.media.MediaScannerConnection.scanFile(this, arrayOf(out.absolutePath), arrayOf(mime), null)
        return out.absolutePath
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

    /** «Добавить на рабочий стол»: the launcher shows its own confirmation (Android 8+). */
    private fun pinWidget(kind: String): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        val manager = getSystemService(AppWidgetManager::class.java) ?: return false
        if (!manager.isRequestPinAppWidgetSupported) return false
        val cls = if (kind == "library") LibraryWidgetProvider::class.java else ContinueWidgetProvider::class.java
        return manager.requestPinAppWidget(ComponentName(this, cls), null, null)
    }

    /** A .cbz/.zip opened with (VIEW) or shared to (SEND) MangaFlow: copy it into the cache for Dart. */
    /** «Открыть файл»: every PDF page to a JPEG (0001.jpg…) [width] px wide, on white. */
    private fun renderPdf(src: File, out: File, width: Int): Int {
        out.mkdirs()
        val fd = android.os.ParcelFileDescriptor.open(src, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            val renderer = android.graphics.pdf.PdfRenderer(fd)
            try {
                for (i in 0 until renderer.pageCount) {
                    val page = renderer.openPage(i)
                    try {
                        val h = (page.height.toLong() * width / page.width.coerceAtLeast(1)).toInt().coerceIn(1, width * 6)
                        val bmp = android.graphics.Bitmap.createBitmap(width, h, android.graphics.Bitmap.Config.ARGB_8888)
                        bmp.eraseColor(android.graphics.Color.WHITE)
                        page.render(bmp, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        File(out, String.format(java.util.Locale.ROOT, "%04d.jpg", i + 1)).outputStream().use {
                            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, it)
                        }
                        bmp.recycle()
                    } finally {
                        page.close()
                    }
                }
                return renderer.pageCount
            } finally {
                renderer.close()
            }
        } finally {
            fd.close()
        }
    }

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
                if (mime == "application/pdf" && !name.endsWith(".pdf", ignoreCase = true)) name += ".pdf"
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
