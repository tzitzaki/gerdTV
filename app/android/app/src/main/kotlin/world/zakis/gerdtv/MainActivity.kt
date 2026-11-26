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
// Channel "gerdtv/platform": Dart → setPlaying(Boolean, String title), nowPlaying(…) and
// clearNowPlaying() (the media session's card, PlaybackService; its play/pause → mediaCommand(String)), setFloating(Boolean), setLogo(String name), installApk(String
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
    private var playingTitle = ""
    /// The running recording's title, or null.
    private var recording: String? = null
    /// The Dart call waiting for the folder picker's answer.
    private var picking: MethodChannel.Result? = null

    /// The foreground service runs while something plays or records.
    private fun updateService() {
        val title = if (playing) playingTitle else recording ?: ""
        val service = Intent(this, PlaybackService::class.java).putExtra("title", title)
        if (playing || recording != null) startForegroundServiceCompat(service) else stopService(service)
    }

    @Suppress("DEPRECATION") // FlutterActivity is no ComponentActivity: no Activity Result API here
    private fun pickFolder(result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        if (intent.resolveActivity(packageManager) == null) {
            result.success(null)
            return
        }
        picking?.success(null)
        picking = result
        startActivityForResult(intent, FOLDER_REQUEST)
    }

    /// Leaving the app floats the picture (Dart decides: lib/player/floating.dart).
    private var floating = false

    /// The Dart call waiting for the speech recognizer's answer (one at a time).
    private var listening: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PlaybackService.onCommand = { action -> channel?.invokeMethod("mediaCommand", action) }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gerdtv/platform").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPlaying" -> {
                        playing = call.argument<Boolean>("playing") ?: false
                        playingTitle = call.argument<String>("title") ?: ""
                        updateService()
                        result.success(null)
                    }
                    // A recording runs: the service keeps the process alive also with nothing playing (it's started
                    // while the app is in front, which Android allows; a recording must not freeze in the background).
                    "setRecording" -> {
                        recording = call.argument<String>("title")
                        updateService()
                        result.success(null)
                    }
                    // The recordings folder: the system's folder picker (null: none on this device, e.g. some TVs).
                    "pickFolder" -> pickFolder(result)
                    // A new file in the picked folder: its descriptor (Rust takes it over) and content URI.
                    "createDocument" -> {
                        try {
                            val tree = android.net.Uri.parse(call.argument<String>("tree"))
                            val parent = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                                tree, android.provider.DocumentsContract.getTreeDocumentId(tree),
                            )
                            val doc = android.provider.DocumentsContract.createDocument(
                                contentResolver, parent, "video/mp2t", call.argument<String>("name") ?: "recording.ts",
                            ) ?: throw java.io.IOException("the folder refused a new file")
                            val fd = contentResolver.openFileDescriptor(doc, "w")!!.detachFd()
                            result.success(mapOf("fd" to fd, "uri" to doc.toString()))
                        } catch (e: Exception) {
                            result.error("folder", e.message, null)
                        }
                    }
                    "deleteDocument" -> {
                        val ok = try {
                            android.provider.DocumentsContract.deleteDocument(
                                contentResolver, android.net.Uri.parse(call.argument<String>("uri")),
                            )
                        } catch (e: Exception) {
                            false
                        }
                        result.success(ok)
                    }
                    // Without a picker: the app's own folder on each mounted drive (USB too); deleted on uninstall.
                    "appFolders" -> result.success(
                        getExternalFilesDirs(android.os.Environment.DIRECTORY_MOVIES).filterNotNull().map { it.path },
                    )
                    "nowPlaying" -> {
                        PlaybackService.show(
                            PlaybackService.Card(
                                title = call.argument<String>("title") ?: "",
                                subtitle = call.argument<String>("subtitle") ?: "",
                                artwork = call.argument<String>("artwork"),
                                playing = call.argument<Boolean>("playing") ?: false,
                                positionMs = ((call.argument<Double>("position") ?: 0.0) * 1000).toLong(),
                                durationMs = ((call.argument<Double>("duration") ?: 0.0) * 1000).toLong(),
                            )
                        )
                        result.success(null)
                    }
                    "isTv" -> result.success(isTv())
                    "takeOpenItem" -> {
                        result.success(openItem(intent))
                        intent.removeExtra(TvHome.EXTRA_ITEM)
                    }
                    "tvHome" -> {
                        val profile = call.argument<String>("profile") ?: ""
                        val resume = call.argument<List<Map<String, Any?>>>("resume") ?: emptyList()
                        val channels = call.argument<List<Map<String, Any?>>>("channels") ?: emptyList()
                        // The launcher's database, off the UI thread and one update at a time.
                        tvHomeThread.execute { TvHome.update(applicationContext, profile, resume, channels) }
                        result.success(null)
                    }
                    // TV only: the display's modes, the current one first (app/lib/player/frame_rate.dart).
                    "displayModes" -> result.success(
                        if (isTv()) {
                            val current = display().mode
                            (listOf(current) + display().supportedModes.filter { m -> m.modeId != current.modeId }).map { m ->
                                mapOf(
                                    "id" to m.modeId, "width" to m.physicalWidth, "height" to m.physicalHeight,
                                    "rate" to m.refreshRate.toDouble(),
                                )
                            }
                        } else emptyList()
                    )
                    // 0: the system's own choice again.
                    "setDisplayMode" -> {
                        window.attributes = window.attributes.apply {
                            preferredDisplayModeId = call.argument<Int>("id") ?: 0
                        }
                        result.success(null)
                    }
                    "clearNowPlaying" -> {
                        PlaybackService.show(null)
                        result.success(null)
                    }
                    "setFloating" -> {
                        floating = call.argument<Boolean>("on") ?: false
                        updatePipParams()
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
                    // The player's brightness swipe: only this window's brightness, the system setting stays
                    // (no permission needed). -1 in the window means "the system's": read that one then.
                    "brightness" -> {
                        val own = window.attributes.screenBrightness
                        result.success(
                            if (own >= 0) own.toDouble()
                            else android.provider.Settings.System.getInt(
                                contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS, 128
                            ) / 255.0
                        )
                    }
                    "setBrightness", "resetBrightness" -> {
                        val value = call.argument<Double>("value")
                        window.attributes = window.attributes.apply {
                            screenBrightness = value?.toFloat()?.coerceIn(0.01f, 1f)
                                ?: android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        }
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
        if (requestCode == FOLDER_REQUEST) {
            val tree = data?.data.takeIf { resultCode == RESULT_OK }
            // Kept across restarts: recordings are written there later, also after a reboot.
            tree?.let {
                contentResolver.takePersistableUriPermission(
                    it, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            picking?.success(tree?.toString() ?: "")
            picking = null
            return
        }
        if (requestCode != VOICE_REQUEST) return
        val text = if (resultCode == RESULT_OK) {
            data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
        } else null
        listening?.success(text)
        listening = null
    }

    private val tvHomeThread = java.util.concurrent.Executors.newSingleThreadExecutor()

    /// What a home screen entry asks for (TvHome), or null for a plain start.
    private fun openItem(intent: Intent): Map<String, String>? {
        val key = intent.getStringExtra(TvHome.EXTRA_ITEM) ?: return null
        return mapOf("profile" to (intent.getStringExtra(TvHome.EXTRA_PROFILE) ?: ""), "key" to key)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openItem(intent)?.let { channel?.invokeMethod("openItem", it) }
    }

    private fun isTv() = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)

    @Suppress("DEPRECATION") // Activity.getDisplay needs Android 11
    private fun display() = windowManager.defaultDisplay

    private fun startForegroundServiceCompat(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    /// Android 12+: enter PiP automatically when the user leaves while floating is on (smoother than onUserLeaveHint).
    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(floating)
        setPictureInPictureParams(builder.build())
    }

    /// Android 8–11: enter PiP by hand when the user leaves (Home, recents) while floating is on.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (floating && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pictureMode", isInPictureInPictureMode)
    }

    private companion object {
        const val VOICE_REQUEST = 7301
        const val FOLDER_REQUEST = 7302
    }
}
