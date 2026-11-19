package com.mangaflow.mangaflow

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widget «Библиотека»: four titles (new chapters first) with covers and «+N» badges.
 * Data: Flutter SharedPreferences keys flutter.widget_lib_*, written by the app and by the
 * background update check. Refreshes on ACTION_REFRESH (sent from Dart) and every 30 min.
 */
class LibraryWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = build(context)
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_REFRESH) {
            refresh(context)
            ContinueWidgetProvider.refresh(context)
            return
        }
        super.onReceive(context, intent)
    }

    companion object {
        const val ACTION_REFRESH = "com.mangaflow.mangaflow.WIDGET_REFRESH"
        private val tiles = intArrayOf(R.id.tile_0, R.id.tile_1, R.id.tile_2, R.id.tile_3)
        private val covers = intArrayOf(R.id.cover_0, R.id.cover_1, R.id.cover_2, R.id.cover_3)
        private val titles = intArrayOf(R.id.title_0, R.id.title_1, R.id.title_2, R.id.title_3)
        private val badges = intArrayOf(R.id.badge_0, R.id.badge_1, R.id.badge_2, R.id.badge_3)

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, LibraryWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = build(context)
            ids.forEach { manager.updateAppWidget(it, views) }
        }

        private fun int(p: android.content.SharedPreferences, key: String): Int =
            try { p.getLong(key, 0L).toInt() } catch (_: ClassCastException) { p.getInt(key, 0) }

        private fun build(context: Context): RemoteViews {
            val p = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.widget_library)
            val count = int(p, "flutter.widget_lib_count").coerceIn(0, 4)
            val fresh = int(p, "flutter.widget_lib_new")
            views.setTextViewText(R.id.lib_new, if (fresh > 0) "Новых глав: $fresh" else "")
            views.setViewVisibility(R.id.lib_empty, if (count == 0) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.lib_row, if (count == 0) View.GONE else View.VISIBLE)
            for (i in 0 until 4) {
                if (i >= count) {
                    views.setViewVisibility(tiles[i], View.INVISIBLE)
                    continue
                }
                views.setViewVisibility(tiles[i], View.VISIBLE)
                views.setTextViewText(titles[i], p.getString("flutter.widget_lib_${i}_title", "") ?: "")
                val badge = p.getString("flutter.widget_lib_${i}_badge", "") ?: ""
                views.setTextViewText(badges[i], badge)
                views.setViewVisibility(badges[i], if (badge.isEmpty()) View.GONE else View.VISIBLE)
                val bmp = p.getString("flutter.widget_lib_${i}_cover", null)?.let { ContinueWidgetProvider.cover(it, 140) }
                if (bmp != null) views.setImageViewBitmap(covers[i], bmp) else views.setImageViewResource(covers[i], R.mipmap.ic_launcher)
                val intent = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    p.getString("flutter.widget_lib_${i}_route", null)?.let { putExtra(ContinueWidgetProvider.EXTRA_ROUTE, it) }
                }
                val pending = PendingIntent.getActivity(
                    context, 4800 + i, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(tiles[i], pending)
            }
            val open = PendingIntent.getActivity(
                context, 4799,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra(ContinueWidgetProvider.EXTRA_ROUTE, "/library")
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.lib_root, open)
            return views
        }
    }
}
