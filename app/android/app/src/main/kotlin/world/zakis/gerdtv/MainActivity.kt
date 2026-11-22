package world.zakis.gerdtv

// The Android side of "playback keeps going" (docs/ARCHITECTURE.md, "Platform channels"):
// - Picture-in-Picture: while something plays, leaving the app (Home, another app) shrinks it to the system's floating
//   window instead of stopping; Dart is told so it shows only the picture (Session.pictureMode).
// - Background playback: PlaybackService (a foreground service with a notification, wake and Wi-Fi locks) keeps the
//   process and the stream alive with the screen off, until Dart says playback stopped.
// - The launcher icon: one <activity-alias> per logo in the manifest, exactly one enabled (setLogo).
// Channel "gerdtv/platform": Dart → setPlaying(Boolean, String title), setLogo(String name); native →
// pictureMode(Boolean).
// Debug hints: `adb shell dumpsys activity services world.zakis.gerdtv` shows the service; PiP needs
// android:supportsPictureInPicture in the manifest and Android 8+.

import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var playing = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gerdtv/platform").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPlaying" -> {
                        playing = call.argument<Boolean>("playing") ?: false
                        val title = call.argument<String>("title") ?: ""
                        updatePipParams()
                        val service = Intent(this, PlaybackService::class.java).putExtra("title", title)
                        if (playing) startForegroundServiceCompat(service) else stopService(service)
                        result.success(null)
                    }
                    "setLogo" -> {
                        setLogo(call.argument<String>("name") ?: "gtv")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// Enables the chosen logo's launcher alias and disables the others. DONT_KILL_APP keeps this process running;
    /// the launcher picks up the new icon after a moment (some launchers drop a home-screen shortcut of the old one).
    private fun setLogo(name: String) {
        val aliases = mapOf("gtv" to "LogoGtv", "screen" to "LogoScreen", "monogram" to "LogoMonogram", "signal" to "LogoSignal")
        val chosen = aliases[name] ?: "LogoGtv"
        // Enable first, then disable the rest: there is always a launcher entry, even if the app dies in between.
        for (alias in listOf(chosen) + aliases.values.filter { it != chosen }) {
            packageManager.setComponentEnabledSetting(
                ComponentName(this, "$packageName.$alias"),
                if (alias == chosen) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    private fun startForegroundServiceCompat(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    /// Android 12+: enter PiP automatically when the user leaves while playing (smoother than onUserLeaveHint).
    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(playing)
        setPictureInPictureParams(builder.build())
    }

    /// Android 8–11: enter PiP by hand when the user leaves (Home, recents) while playing.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (playing && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pictureMode", isInPictureInPictureMode)
    }
}
