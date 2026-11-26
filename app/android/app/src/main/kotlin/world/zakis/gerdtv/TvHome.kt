package world.zakis.gerdtv

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.media.tv.TvContract
import android.net.Uri
import android.os.Build
import android.util.Log

// The Android TV home screen: Play Next holds what Continue watching holds, and a "gerdTV" channel row the channels
// watched last. Dart sends the whole wanted state (app/lib/services/tv_home.dart); this makes the launcher's tables
// match it. The TV provider allows no WHERE clauses, so rows are read (an app sees only its own) and changed by id.
// A programme the user removed from Play Next stays in the table as not browsable: it is left alone, so it never
// comes back (Google's rule), until it leaves Continue watching.
// Debugging: `adb logcat -s TvHome`; a launcher without the TV provider throws on the first query.
object TvHome {
    private const val TAG = "TvHome"
    const val EXTRA_PROFILE = "world.zakis.gerdtv.PROFILE"
    const val EXTRA_ITEM = "world.zakis.gerdtv.ITEM"

    fun update(context: Context, profile: String, resume: List<Map<String, Any?>>, channels: List<Map<String, Any?>>) {
        // Android 7 has no such home screen, nor these classes (an Error, which the catch below wouldn't take).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            reconcile(context, TvContract.WatchNextPrograms.CONTENT_URI, resume.associateBy { it["key"] as String }) { r ->
                common(context, profile, r).apply {
                    val episode = r["episode"] == true
                    put(
                        TvContract.WatchNextPrograms.COLUMN_TYPE,
                        if (episode) TvContract.PreviewPrograms.TYPE_TV_EPISODE else TvContract.PreviewPrograms.TYPE_MOVIE,
                    )
                    put(TvContract.WatchNextPrograms.COLUMN_WATCH_NEXT_TYPE, TvContract.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE)
                    // The list is last watched first: the order is kept by counting back from now.
                    put(
                        TvContract.WatchNextPrograms.COLUMN_LAST_ENGAGEMENT_TIME_UTC_MILLIS,
                        System.currentTimeMillis() - resume.indexOf(r) * 60_000L,
                    )
                    put(TvContract.WatchNextPrograms.COLUMN_LAST_PLAYBACK_POSITION_MILLIS, (r["position"] as Int) * 1000)
                    put(TvContract.WatchNextPrograms.COLUMN_DURATION_MILLIS, (r["duration"] as Int) * 1000)
                }
            }
            val channel = channel(context) ?: return
            reconcile(context, TvContract.PreviewPrograms.CONTENT_URI, channels.associateBy { it["key"] as String }) { c ->
                common(context, profile, c).apply {
                    put(TvContract.PreviewPrograms.COLUMN_CHANNEL_ID, channel)
                    put(TvContract.PreviewPrograms.COLUMN_TYPE, TvContract.PreviewPrograms.TYPE_CHANNEL)
                    put(TvContract.PreviewPrograms.COLUMN_POSTER_ART_ASPECT_RATIO, TvContract.PreviewPrograms.ASPECT_RATIO_1_1)
                    put(TvContract.PreviewPrograms.COLUMN_WEIGHT, channels.size - channels.indexOf(c))
                }
            }
        } catch (e: Exception) {
            // The TV provider belongs to the launcher; an unusual one must not take the app down.
            Log.w(TAG, "home screen not updated", e)
        }
    }

    private fun common(context: Context, profile: String, r: Map<String, Any?>) = ContentValues().apply {
        // Both tables name these columns alike (TvContract.BaseTvColumns).
        put(TvContract.PreviewPrograms.COLUMN_TITLE, r["title"] as String)
        put(TvContract.PreviewPrograms.COLUMN_INTERNAL_PROVIDER_ID, r["key"] as String)
        (r["art"] as? String)?.takeIf { it.startsWith("http") }?.let { put(TvContract.PreviewPrograms.COLUMN_POSTER_ART_URI, it) }
        val intent = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .putExtra(EXTRA_PROFILE, profile)
            .putExtra(EXTRA_ITEM, r["key"] as String)
        put(TvContract.PreviewPrograms.COLUMN_INTENT_URI, intent.toUri(Intent.URI_INTENT_SCHEME))
    }

    private fun reconcile(
        context: Context, table: Uri, wanted: Map<String, Map<String, Any?>>, values: (Map<String, Any?>) -> ContentValues,
    ) {
        val resolver = context.contentResolver
        val missing = wanted.toMutableMap()
        val columns = arrayOf(
            "_id", TvContract.PreviewPrograms.COLUMN_INTERNAL_PROVIDER_ID, TvContract.PreviewPrograms.COLUMN_BROWSABLE,
        )
        resolver.query(table, columns, null, null, null)?.use { c: Cursor ->
            while (c.moveToNext()) {
                val row = Uri.withAppendedPath(table, c.getLong(0).toString())
                val want = missing.remove(c.getString(1))
                when {
                    want == null -> resolver.delete(row, null, null)
                    c.getInt(2) == 0 && table == TvContract.WatchNextPrograms.CONTENT_URI -> Unit // dismissed
                    else -> resolver.update(row, values(want), null, null)
                }
            }
        }
        for (w in missing.values) resolver.insert(table, values(w))
    }

    /** gerdTV's row, made once; the launcher shows an app's first channel by itself. */
    private fun channel(context: Context): Long? {
        val resolver = context.contentResolver
        resolver.query(TvContract.Channels.CONTENT_URI, arrayOf("_id"), null, null, null)?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }
        val uri = resolver.insert(
            TvContract.Channels.CONTENT_URI,
            ContentValues().apply {
                put(TvContract.Channels.COLUMN_TYPE, TvContract.Channels.TYPE_PREVIEW)
                put(TvContract.Channels.COLUMN_DISPLAY_NAME, "gerdTV")
                put(
                    TvContract.Channels.COLUMN_APP_LINK_INTENT_URI,
                    Intent(context, MainActivity::class.java).toUri(Intent.URI_INTENT_SCHEME),
                )
            },
        )
        return uri?.lastPathSegment?.toLong()
    }
}
