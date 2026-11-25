package world.zakis.gerdtv

// Keeps the stream playing with the screen off or the app in the background: a foreground service (type
// mediaPlayback) with an ongoing notification, a partial wake lock (CPU stays on) and a Wi-Fi lock (the radio stays in
// full-performance mode). Started and stopped by MainActivity when Dart reports playback; tapping the notification
// opens the app. It also shows the media session's card (lock screen, quick settings): what plays, with
// play/pause (Dart: lib/services/media_card.dart). Without it Android may freeze or kill the app soon after the screen goes off.

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        session = MediaSession(this, "gerdTV").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { onCommand?.invoke("play") }
                override fun onPause() { onCommand?.invoke("pause") }
            })
            isActive = true
        }
        refreshSession()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PLAY || intent?.action == ACTION_PAUSE) {
            onCommand?.invoke(if (intent.action == ACTION_PLAY) "play" else "pause")
            // The notification outlived the service by a moment: nothing to keep running.
            if (wakeLock == null) stopSelf()
            return START_NOT_STICKY
        }
        title = intent?.getStringExtra("title").orEmpty()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gerdtv:playback").apply { acquire() }
        }
        if (wifiLock == null) {
            @Suppress("DEPRECATION") // WIFI_MODE_FULL_HIGH_PERF: the replacement (low latency) needs the screen on
            wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "gerdtv:playback").apply { acquire() }
        }
        return START_NOT_STICKY // after a crash there is no stream to resume; don't restart the service empty
    }

    override fun onDestroy() {
        instance = null
        session?.release()
        session = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        super.onDestroy()
    }

    private var title = ""

    /// The session's state and metadata: what the lock screen and quick settings show. No seeking (owner decision),
    /// so only play/pause are offered; live has no duration.
    private fun refreshSession() {
        val card = card ?: return
        session?.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, card.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, card.subtitle)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, if (card.durationMs > 0) card.durationMs else -1)
                .apply {
                    card.artwork?.let { BitmapFactory.decodeFile(it) }
                        ?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
                }
                .build()
        )
        session?.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE)
                .setState(
                    if (card.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    if (card.durationMs > 0) card.positionMs else PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    if (card.playing) 1f else 0f,
                )
                .build()
        )
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val card = card
        if (card != null) {
            val toggle = PendingIntent.getService(
                this, 1,
                Intent(this, PlaybackService::class.java).setAction(if (card.playing) ACTION_PAUSE else ACTION_PLAY),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val icon = if (card.playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
            val label = if (card.playing) "Pause" else "Play"
            builder.addAction(Notification.Action.Builder(Icon.createWithResource(this, icon), label, toggle).build())
            builder.setStyle(
                Notification.MediaStyle().setMediaSession(session?.sessionToken).setShowActionsInCompactView(0)
            )
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)  // the lock screen shows it
        }
        return builder
            .setContentTitle(card?.title ?: "gerdTV")
            .setContentText(card?.subtitle ?: title)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "playback"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_PLAY = "world.zakis.gerdtv.PLAY"
        private const val ACTION_PAUSE = "world.zakis.gerdtv.PAUSE"

        /// Same process as the activity: no binding needed. Starting a service for every change is not allowed in
        /// the background.
        private var instance: PlaybackService? = null
        private var card: Card? = null

        /// "play" or "pause" from the card or a headset, to Dart (set by MainActivity).
        var onCommand: ((String) -> Unit)? = null

        /// What the card shows; null when playback stopped. Before the service runs it only remembers.
        fun show(next: Card?) {
            card = next
            val service = instance ?: return
            if (next == null) return
            service.refreshSession()
            (service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, service.buildNotification())
        }
    }

    class Card(
        val title: String,
        val subtitle: String,
        val artwork: String?,
        val playing: Boolean,
        val positionMs: Long,
        val durationMs: Long,
    )
}
