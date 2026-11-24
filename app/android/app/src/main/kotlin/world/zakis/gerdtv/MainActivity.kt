package world.zakis.gerdtv

// The Android side of "playback keeps going" (docs/ARCHITECTURE.md, "Platform channels"):
// - Picture-in-Picture: while something plays, leaving the app (Home, another app) shrinks it to the system's floating
//   window instead of stopping; Dart is told so it shows only the picture (Session.pictureMode).
// - Background playback: PlaybackService (a foreground service with a notification, wake and Wi-Fi locks) keeps the
//   process and the stream alive with the screen off, until Dart says playback stopped.
// - The launcher icon: one <activity-alias> per logo in the manifest, exactly one enabled (setLogo).
// - Voice search: the search field's mic starts the system's speech recognizer (RecognizerIntent); it records, so
//   gerdTV needs no microphone permission. voiceAvailable says whether one is installed (<queries> in the manifest).
// - Updates: installApk hands the downloaded APK to the system's installer through a FileProvider (res/xml/
//   file_paths.xml); the user confirms there, and allows "install unknown apps" for gerdTV the first time.
// - Settings → Your data: saveToDownloads writes the export into the public Downloads folder (MediaStore, Android
//   10+, no permission needed); older Android gets the app's own Downloads folder and the path is returned.
// Channel "gerdtv/platform": Dart → setPlaying(Boolean, String title), setLogo(String name), installApk(String
// path), saveToDownloads(String name, String text) → String, voiceAvailable(), listen(String prompt) → String?
// (null: cancelled or nothing heard); native →
// pictureMode(Boolean).
// Debug hints: `adb shell dumpsys activity services world.zakis.gerdtv` shows the service; PiP needs
// android:supportsPictureInPicture in the manifest and Android 8+.

import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.ContentValues
import android.content.res.Configuration
import android.os.Environment
import android.provider.MediaStore
import android.os.Build
import android.speech.RecognizerIntent
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var playing = false

    /// The Dart call waiting for the speech recognizer's answer (one at a time).
    private var listening: MethodChannel.Result? = null

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
                    "voiceAvailable" -> result.success(speechIntent("").resolveActivity(packageManager) != null)
                    "listen" -> listen(call.argument<String>("prompt") ?: "", result)
                    "installApk" -> {
                        val apk = java.io.File(call.argument<String>("path") ?: "")
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", apk)
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "openUrl" -> {
                        // A TV may have no browser: false lets Dart show the address instead.
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, android.net.Uri.parse(call.argument<String>("url") ?: ""))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: android.content.ActivityNotFoundException) {
                            result.success(false)
                        }
                    }
                    "saveToDownloads" -> {
                        val name = call.argument<String>("name") ?: "gerdtv.json"
                        val text = call.argument<String>("text") ?: ""
                        try {
                            result.success(saveToDownloads(name, text.toByteArray()))
                        } catch (e: Exception) {
                            result.error("save", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// Writes [bytes] as [name] into Downloads; returns where it went (shown to the user).
    private fun saveToDownloads(name: String, bytes: ByteArray): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val file = java.io.File(dir, name)
            file.writeBytes(bytes)
            return file.path
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/json")
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw java.io.IOException("Downloads refused the file")
        contentResolver.openOutputStream(uri).use { it!!.write(bytes) }
        return "Downloads/$name"
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

    private fun speechIntent(prompt: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_WEB_SEARCH)
        .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        .putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)

    /// Starts the recognizer; its answer arrives in onActivityResult. A recognizer that vanished since voiceAvailable
    /// (uninstalled) answers null instead of crashing.
    @Suppress("DEPRECATION") // FlutterActivity is no ComponentActivity: no Activity Result API here
    private fun listen(prompt: String, result: MethodChannel.Result) {
        listening?.success(null)
        listening = result
        try {
            startActivityForResult(speechIntent(prompt), VOICE_REQUEST)
        } catch (e: android.content.ActivityNotFoundException) {
            listening = null
            result.success(null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VOICE_REQUEST) return
        val text = if (resultCode == RESULT_OK) {
            data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
        } else null
        listening?.success(text)
        listening = null
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

    private companion object {
        const val VOICE_REQUEST = 7301
    }
}
