package com.mangaflow.mangaflow.upscale

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import java.util.Collections
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * On-device manga page upscaling (waifu2x models on ONNX Runtime), channel `mangaflow/upscale`.
 *
 * One job at a time on a low-priority background thread; Dart decides what to queue.
 *   upscale {id, input, output, model, maxSourceWidth, maxOutPixels} → {status, ms, width, height, tiles, skippedTiles}
 *   cancel {id} · release
 */
class UpscalePlugin(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "mangaflow/upscale").also { it.setMethodCallHandler(this) }
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(Runnable {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, "mf-upscale")
    }
    private val cancelled = Collections.synchronizedSet(HashSet<String>())
    private var env: OrtEnvironment? = null
    private var session: OrtSession? = null
    private var sessionModel: String? = null

    private class Model(val asset: String, val spec: ModelSpec)

    private val models = mapOf(
        "fast" to Model("assets/models/waifu2x_cunet_art_noise1_scale2x.onnx", ModelSpec(scale = 2, offset = 36, tile = 196)),
        "max" to Model("assets/models/waifu2x_swin_art_scan_noise1_scale2x.onnx", ModelSpec(scale = 2, offset = 16, tile = 160)),
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "upscale" -> {
                val id = call.argument<String>("id") ?: ""
                val input = call.argument<String>("input")
                val output = call.argument<String>("output")
                val model = models[call.argument<String>("model") ?: "fast"]
                val maxSourceWidth = call.argument<Int>("maxSourceWidth") ?: 1800
                val maxOutPixels = (call.argument<Number>("maxOutPixels") ?: 24_000_000).toLong()
                if (input == null || output == null || model == null) {
                    result.error("bad_args", "input/output/model required", null)
                    return
                }
                executor.execute {
                    val reply = try {
                        if (cancelled.remove(id)) mapOf("status" to "cancelled")
                        else upscale(id, input, output, call.argument<String>("model") ?: "fast", model, maxSourceWidth, maxOutPixels)
                    } catch (e: CancelledException) {
                        mapOf("status" to "cancelled")
                    } catch (e: OutOfMemoryError) {
                        releaseSession()
                        mapOf("status" to "error", "message" to "out_of_memory")
                    } catch (e: Throwable) {
                        Log.w(TAG, "upscale failed", e)
                        mapOf("status" to "error", "message" to (e.message ?: e.javaClass.simpleName))
                    } finally {
                        cancelled.remove(id)
                    }
                    main.post { result.success(reply) }
                }
            }
            "cancel" -> {
                call.argument<String>("id")?.let { cancelled.add(it) }
                result.success(null)
            }
            "release" -> {
                executor.execute { releaseSession() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun upscale(
        id: String,
        input: String,
        output: String,
        modelKey: String,
        model: Model,
        maxSourceWidth: Int,
        maxOutPixels: Long,
    ): Map<String, Any> {
        val t0 = SystemClock.elapsedRealtime()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(input, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) return mapOf("status" to "error", "message" to "decode_bounds")
        val s = model.spec.scale
        if (w >= maxSourceWidth) return mapOf("status" to "skipped", "reason" to "large_enough", "width" to w, "height" to h)
        if (w.toLong() * h * s * s > maxOutPixels) return mapOf("status" to "skipped", "reason" to "too_large", "width" to w, "height" to h)

        val src = BitmapFactory.decodeFile(input, BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 })
            ?: return mapOf("status" to "error", "message" to "decode")
        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)
        src.recycle()
        val gray = TiledUpscaler.isGrayscale(pixels)

        val ses = session(modelKey, model)
        val ortEnv = env!!
        val tileModel = TileModel { buf, size ->
            OnnxTensor.createTensor(ortEnv, FloatBuffer.wrap(buf), longArrayOf(1, 3, size.toLong(), size.toLong())).use { t ->
                ses.run(mapOf("x" to t)).use { r ->
                    val fb = (r.get(0) as OnnxTensor).floatBuffer
                    FloatArray(fb.remaining()).also { fb.get(it) }
                }
            }
        }
        val ow = w * s
        val oh = h * s
        val out = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
        val engine = TiledUpscaler(model.spec, tileModel)
        try {
            engine.process(pixels, w, h, gray, isCancelled = { cancelled.contains(id) }) { r0, rows, data ->
                out.setPixels(data, 0, ow, 0, r0, ow, rows)
            }
            val dst = File(output)
            dst.parentFile?.mkdirs()
            val tmp = File(dst.parentFile, dst.name + ".part")
            FileOutputStream(tmp).use { os -> out.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, os) }
            if (!tmp.renameTo(dst)) {
                tmp.copyTo(dst, overwrite = true)
                tmp.delete()
            }
        } finally {
            out.recycle()
        }
        return mapOf(
            "status" to "ok",
            "ms" to (SystemClock.elapsedRealtime() - t0).toInt(),
            "width" to ow,
            "height" to oh,
            "gray" to gray,
            "tiles" to engine.tilesTotal,
            "skippedTiles" to engine.tilesSkipped,
        )
    }

    private fun session(key: String, model: Model): OrtSession {
        session?.let { if (sessionModel == key) return it }
        releaseSession()
        val e = env ?: OrtEnvironment.getEnvironment().also { env = it }
        val loader = FlutterInjector.instance().flutterLoader()
        val bytes = context.assets.open(loader.getLookupKeyForAsset(model.asset)).use { it.readBytes() }
        val threads = max(1, min(4, Runtime.getRuntime().availableProcessors() - 2))
        val opts = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(threads)
            setInterOpNumThreads(1)
            // Don't busy-wait between tiles: saves battery and keeps the UI thread smooth.
            addConfigEntry("session.intra_op.allow_spinning", "0")
        }
        return e.createSession(bytes, opts).also {
            session = it
            sessionModel = key
        }
    }

    private fun releaseSession() {
        try {
            session?.close()
        } catch (_: Throwable) {
        }
        session = null
        sessionModel = null
    }

    companion object {
        private const val TAG = "MangaFlowUpscale"
        private const val JPEG_QUALITY = 93
    }
}
