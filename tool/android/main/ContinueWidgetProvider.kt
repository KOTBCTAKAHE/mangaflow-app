package com.mangaflow.mangaflow

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.widget.RemoteViews

/**
 * Home-screen widget "Продолжить чтение": cover, title, chapter, progress; tap → reader.
 * Data comes from Flutter's SharedPreferences (keys flutter.widget_*), written by the app.
 */
class ContinueWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = build(context)
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == LibraryWidgetProvider.ACTION_REFRESH) {
            refresh(context)
            LibraryWidgetProvider.refresh(context)
            return
        }
        super.onReceive(context, intent)
    }

    companion object {
        const val EXTRA_ROUTE = "mf_route"

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, ContinueWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = build(context)
            ids.forEach { manager.updateAppWidget(it, views) }
        }

        private fun build(context: Context): RemoteViews {
            val p = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.widget_continue)
            val title = p.getString("flutter.widget_title", null)
            if (title == null) {
                views.setTextViewText(R.id.widget_title, "Начните читать")
                views.setTextViewText(R.id.widget_chapter, "Здесь появится последняя глава")
                views.setProgressBar(R.id.widget_progress, 100, 0, false)
            } else {
                views.setTextViewText(R.id.widget_title, title)
                views.setTextViewText(R.id.widget_chapter, p.getString("flutter.widget_chapter", "") ?: "")
                val progress = try { p.getLong("flutter.widget_progress", 0L).toInt() } catch (_: ClassCastException) { 0 }
                views.setProgressBar(R.id.widget_progress, 100, progress.coerceIn(0, 100), false)
                p.getString("flutter.widget_cover", null)?.let { path -> cover(path)?.let { views.setImageViewBitmap(R.id.widget_cover, it) } }
            }
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                p.getString("flutter.widget_route", null)?.let { putExtra(EXTRA_ROUTE, it) }
            }
            val pending = PendingIntent.getActivity(
                context, 4712, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root, pending)
            return views
        }

        /** Small rounded bitmap (RemoteViews have a size budget and can't clip). */
        fun cover(path: String, width: Int = 160): Bitmap? = try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= width) sample *= 2
            val src = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: null
            src?.let {
                val w = width
                val h = (w * 1.42f).toInt()
                val scaled = Bitmap.createScaledBitmap(it, w, h, true)
                val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
                Canvas(out).drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), 18f, 18f, paint)
                if (scaled != it) scaled.recycle()
                it.recycle()
                out
            }
        } catch (_: Throwable) {
            null
        }
    }
}
