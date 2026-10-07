package com.nightwalker.securechat

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.view.WindowManager
import android.webkit.WebView
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.TimeZone

/// Screenshot / screen-recording prevention. Android's FLAG_SECURE,
/// applied to this Activity's window, tells the OS to refuse to capture
/// whatever is currently on screen — a screenshot comes back blank/black
/// (or is blocked outright, depending on OEM/launcher), and screen
/// recording + the "recent apps" thumbnail are blocked the same way. This
/// is exactly the flag Signal and WhatsApp both set on their chat
/// screens.
///
/// The flag is a property of the whole native window, not something
/// Android lets a Flutter app set "for just one screen" on its own — so
/// this exposes it as a tiny MethodChannel that the Dart side
/// (ScreenshotGuardService) calls to enable/disable it as the person
/// enters and leaves screens that should be protected (chat screens,
/// group chat, fullscreen media viewers, the safety-number screen).
/// Screens that were never asking for it (login, settings, etc.) are
/// unaffected.
// UPDATED for the biometric-unlock feature: local_auth's Android side needs
// a FragmentActivity to show the native BiometricPrompt dialog — the plain
// FlutterActivity this used to extend doesn't support it and biometric
// prompts would silently fail/crash. FlutterFragmentActivity is Flutter's
// own drop-in FragmentActivity subclass made for exactly this, so nothing
// else about how this Activity behaves changes.
//
// UPDATED (screenshot alert + recents preview):
//  * "setRecentsHidden" — Android 13+ can blank JUST the recent-apps
//    thumbnail (Activity.setRecentsScreenshotEnabled) without blocking
//    screenshots elsewhere. Returns false on older Android so the Dart side
//    can fall back to FLAG_SECURE instead.
//  * Screenshot detection — Android 14+ has an official callback
//    (Activity.ScreenCaptureCallback) that fires when the person presses the
//    screenshot button combo while this Activity is visible. It needs the
//    DETECT_SCREEN_CAPTURE permission (see AndroidManifest.xml). It is
//    registered in onStart and removed in onStop, as Android requires. On
//    Android 13 and older there is no such API, so nothing is sent.
//
// UPDATED (custom notification sound): a second tiny channel,
// "notification_sound", opens Android's own ringtone picker so the person can
// choose any notification tone installed on the phone (or "Silent"), and
// hands the chosen sound's address + display name back to Dart
// (NotificationSoundService). No permission is needed for the picker itself.
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.nightwalker.securechat/screenshot_guard"
    private var channel: MethodChannel? = null
    private var screenCaptureCallback: Activity.ScreenCaptureCallback? = null

    private val soundChannelName = "com.nightwalker.securechat/notification_sound"
    // Feature: full-screen ringing. While a call is ringing or in progress the
    // window may show over the lock screen and light the display; it is
    // switched back off the moment the call is over (and whenever the app
    // goes out of view), so NWisp never stays visible on a locked phone.
    private val callWindowChannelName = "com.nightwalker.securechat/call_window"

    // Feature: call recording alerts. While a call is on, Dart asks us to
    // watch for OTHER apps recording sound. NWisp's own microphone is one
    // recording, so more than one active recording means another app is
    // recording too. Best-effort only: it can't see other devices.
    private val callRecordingChannelName = "com.nightwalker.securechat/call_recording"
    private var callRecordingChannel: MethodChannel? = null
    private var recordingCallback: android.media.AudioManager.AudioRecordingCallback? = null

    private fun startRecordingWatch() {
        if (Build.VERSION.SDK_INT < 24 || recordingCallback != null) return
        val am = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val cb = object : android.media.AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<android.media.AudioRecordingConfiguration>?) {
                val others = (configs?.size ?: 0) - 1
                runOnUiThread { callRecordingChannel?.invokeMethod("state", others > 0) }
            }
        }
        recordingCallback = cb
        am.registerAudioRecordingCallback(cb, android.os.Handler(android.os.Looper.getMainLooper()))
    }

    private fun stopRecordingWatch() {
        if (Build.VERSION.SDK_INT < 24) return
        val cb = recordingCallback ?: return
        try {
            (getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager).unregisterAudioRecordingCallback(cb)
        } catch (e: Exception) {
            // Already unregistered.
        }
        recordingCallback = null
    }

    // Feature: "Report a problem" (Settings). Three small jobs for the Dart side:
    //  * deviceDetails  - phone / Android / app / battery / storage / network
    //                     facts that help fix a bug. Nothing personal: no
    //                     account, phone number, contacts, IP address,
    //                     location or message content.
    //  * composeEmail   - opens Gmail (or any email app) with the report
    //                     already filled in; the person only presses send.
    //  * takeNativeCrash - returns (and deletes) the stack trace of the last
    //                     crash in the Android layer, if there was one.
    private val reportChannelName = "com.nightwalker.securechat/report"

    companion object {
        private var crashRecorderInstalled = false
        private const val CRASH_FILE = "last_native_crash.txt"
    }

    /// Writes the stack trace of an uncaught crash to a small file, then lets
    /// Android carry on crashing as normal. Next start, the Dart side offers
    /// to send a report about it. Installed once per process.
    private fun installCrashRecorder() {
        if (crashRecorderInstalled) return
        crashRecorderInstalled = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val writer = java.io.StringWriter()
                error.printStackTrace(java.io.PrintWriter(writer))
                File(filesDir, CRASH_FILE).writeText(
                    "time=" + System.currentTimeMillis() + "\nthread=" + thread.name + "\n" + writer.toString().take(6000)
                )
            } catch (e: Throwable) {
                // Recording the crash must never get in the way of the crash itself.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    private fun takeNativeCrash(): String? {
        val file = File(filesDir, CRASH_FILE)
        if (!file.exists()) return null
        return try {
            val text = file.readText()
            file.delete()
            text
        } catch (e: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun collectDeviceDetails(): Map<String, String> {
        val out = linkedMapOf<String, String>()

        try {
            val info = packageManager.getPackageInfo(packageName, 0)
            val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            out["App version"] = "${info.versionName} (build $code)"
            val installer = if (Build.VERSION.SDK_INT >= 30) {
                packageManager.getInstallSourceInfo(packageName).installingPackageName
            } else {
                packageManager.getInstallerPackageName(packageName)
            }
            out["Installed from"] = when (installer) {
                null -> "Direct install (APK)"
                "com.android.vending" -> "Google Play"
                else -> installer.toString()
            }
        } catch (e: Exception) {
        }

        out["Android"] = "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
        out["Security patch"] = Build.VERSION.SECURITY_PATCH ?: "unknown"
        out["Device"] = "${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})"
        out["Brand / hardware"] = "${Build.BRAND} / ${Build.HARDWARE}"
        out["CPU types"] = Build.SUPPORTED_ABIS.joinToString(", ")
        out["System build"] = Build.DISPLAY ?: "unknown"

        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mem = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mem)
            val mb = 1024L * 1024L
            out["Memory"] = "${mem.availMem / mb} MB free of ${mem.totalMem / mb} MB" +
                (if (mem.lowMemory) " (low memory)" else "") +
                (if (am.isLowRamDevice) ", low-RAM device" else "")
        } catch (e: Exception) {
        }

        try {
            val stat = StatFs(filesDir.path)
            val gb = 1024.0 * 1024.0 * 1024.0
            out["Storage"] = String.format(Locale.US, "%.1f GB free of %.1f GB", stat.availableBytes / gb, stat.totalBytes / gb)
        } catch (e: Exception) {
        }

        try {
            val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            val parts = mutableListOf<String>()
            if (level >= 0 && scale > 0) parts.add("${level * 100 / scale}%")
            parts.add(if (charging) "charging" else "not charging")
            if (power.isPowerSaveMode) parts.add("battery saver ON")
            parts.add(if (power.isIgnoringBatteryOptimizations(packageName)) "NWisp exempt from battery optimisation" else "NWisp battery-optimised")
            out["Battery"] = parts.joinToString(", ")
        } catch (e: Exception) {
        }

        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            out["Network"] = when {
                caps == null -> "offline"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile data"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                else -> "other"
            }
        } catch (e: Exception) {
        }

        val metrics = resources.displayMetrics
        out["Screen"] = "${metrics.widthPixels}x${metrics.heightPixels}px, ${metrics.densityDpi} dpi, font scale ${resources.configuration.fontScale}"
        val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        out["System dark mode"] = if (night) "on" else "off"
        out["System language"] = Locale.getDefault().toLanguageTag()
        // Only the offset from UTC, not the region's name.
        val offsetMinutes = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 60000
        out["Time zone offset"] = String.format(Locale.US, "UTC%+d:%02d", offsetMinutes / 60, Math.abs(offsetMinutes % 60))

        if (Build.VERSION.SDK_INT >= 24) {
            try {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                out["Notifications allowed"] = if (nm.areNotificationsEnabled()) "yes" else "no"
            } catch (e: Exception) {
            }
        }

        if (Build.VERSION.SDK_INT >= 26) {
            try {
                val webView = WebView.getCurrentWebViewPackage()
                if (webView != null) out["WebView"] = "${webView.packageName} ${webView.versionName}"
            } catch (e: Exception) {
            }
        }

        try {
            out["Google Play services"] = packageManager.getPackageInfo("com.google.android.gms", 0).versionName ?: "installed"
        } catch (e: Exception) {
            out["Google Play services"] = "not installed"
        }
        return out
    }

    /// Opens Gmail with the report filled in. If Gmail isn't installed, any
    /// other email app is offered instead. Returns "gmail", "other" or "none".
    private fun composeEmail(to: String, subject: String, body: String): String {
        val base = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("mailto:")
            putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
        }
        try {
            startActivity(Intent(base).setPackage("com.google.android.gm"))
            return "gmail"
        } catch (e: Exception) {
        }
        try {
            startActivity(Intent.createChooser(base, "Send report"))
            return "other"
        } catch (e: Exception) {
        }
        return "none"
    }

    private fun setCallWindow(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            if (on) {
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            } else {
                window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
        }
    }

    // The call notification's full-screen intent carries a payload like
    // "call|<id>" / "gcall|<id>". Seeing it here lets the window appear over
    // the lock screen even before the Dart side has started.
    private fun applyCallIntent(intent: Intent?) {
        val payload = intent?.getStringExtra("payload") ?: return
        if (payload.startsWith("call|") || payload.startsWith("gcall|")) setCallWindow(true)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        installCrashRecorder()
        applyCallIntent(intent)
        collectShare(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        applyCallIntent(intent)
        if (collectShare(intent)) {
            // The app was already running: tell Dart straight away.
            runOnUiThread { shareChannel?.invokeMethod("shareReceived", null) }
        }
    }

    // ------------------------------------------------------------------
    // Feature: Share to NWisp from other apps.
    // Android hands the shared text / pictures / videos to this Activity
    // (see the SEND intent filters in AndroidManifest.xml). Shared files
    // arrive as temporary "content://" addresses that stop working soon, so
    // each is copied into the app's own cache folder right away. Dart picks
    // the result up with "takePending".
    // ------------------------------------------------------------------
    private val shareChannelName = "com.nightwalker.securechat/share"
    private var shareChannel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null

    private fun collectShare(intent: Intent?): Boolean {
        if (intent == null) return false
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return false
        try {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            val uris = ArrayList<Uri>()
            @Suppress("DEPRECATION")
            if (action == Intent.ACTION_SEND) {
                val u = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (u != null) uris.add(u)
            } else {
                val l = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (l != null) uris.addAll(l)
            }
            val dir = File(cacheDir, "shared")
            if (dir.exists()) dir.listFiles()?.forEach { it.delete() } else dir.mkdirs()
            val files = ArrayList<Map<String, String>>()
            for ((i, uri) in uris.take(10).withIndex()) {
                val mime = contentResolver.getType(uri) ?: "application/octet-stream"
                if (!mime.startsWith("image/") && !mime.startsWith("video/")) continue
                val ext = when {
                    mime == "image/png" -> "png"
                    mime == "image/webp" -> "webp"
                    mime == "image/gif" -> "gif"
                    mime.startsWith("image/") -> "jpg"
                    mime == "video/webm" -> "webm"
                    else -> "mp4"
                }
                val out = File(dir, "share_${System.currentTimeMillis()}_$i.$ext")
                contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
                if (out.exists() && out.length() > 0) files.add(mapOf("path" to out.absolutePath, "mime" to mime))
            }
            if (text.isNullOrBlank() && files.isEmpty()) return false
            pendingShare = mapOf("text" to text, "files" to files)
            return true
        } catch (e: Exception) {
            return false
        }
    }

    // ------------------------------------------------------------------
    // Feature: update guard / tamper check. Reports this app's own version
    // and the SHA-256 fingerprint of the certificate it is SIGNED with. A copy
    // that was edited and re-signed (MT Manager, apktool …) is signed with a
    // different certificate, which the Dart side (IntegrityService) notices.
    // ------------------------------------------------------------------
    private val integrityChannelName = "com.nightwalker.securechat/integrity"

    @Suppress("DEPRECATION")
    private fun appInfo(): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        try {
            val flags = if (Build.VERSION.SDK_INT >= 28) android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES else android.content.pm.PackageManager.GET_SIGNATURES
            val info = packageManager.getPackageInfo(packageName, flags)
            out["versionName"] = info.versionName
            out["versionCode"] = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            val sigs = if (Build.VERSION.SDK_INT >= 28) {
                val si = info.signingInfo
                if (si == null) emptyArray<android.content.pm.Signature>() else if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
            } else info.signatures
            val md = java.security.MessageDigest.getInstance("SHA-256")
            out["certs"] = (sigs ?: emptyArray<android.content.pm.Signature>()).map { s ->
                md.reset()
                md.digest(s.toByteArray()).joinToString("") { b -> "%02x".format(b) }
            }
            out["debuggable"] = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
            val installer = if (Build.VERSION.SDK_INT >= 30) packageManager.getInstallSourceInfo(packageName).installingPackageName else packageManager.getInstallerPackageName(packageName)
            out["installer"] = installer
        } catch (e: Exception) {
            out["error"] = e.toString()
        }
        return out
    }

    private val soundRequestCode = 4711
    private var pendingSoundResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, integrityChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "appInfo" -> result.success(appInfo())
                "killProcess" -> {
                    result.success(true)
                    android.os.Process.killProcess(android.os.Process.myPid())
                }
                else -> result.notImplemented()
            }
        }
        val sc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName)
        shareChannel = sc
        sc.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> {
                    val s = pendingShare
                    pendingShare = null
                    result.success(s)
                }
                else -> result.notImplemented()
            }
        }
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    runOnUiThread {
                        window.setFlags(
                            WindowManager.LayoutParams.FLAG_SECURE,
                            WindowManager.LayoutParams.FLAG_SECURE
                        )
                    }
                    result.success(null)
                }
                "disable" -> {
                    runOnUiThread {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                "setRecentsHidden" -> {
                    val hidden = call.argument<Boolean>("hidden") ?: false
                    if (Build.VERSION.SDK_INT >= 33) {
                        runOnUiThread { setRecentsScreenshotEnabled(!hidden) }
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, reportChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceDetails" -> result.success(collectDeviceDetails())
                "composeEmail" -> {
                    val to = call.argument<String>("to") ?: ""
                    val subject = call.argument<String>("subject") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    result.success(composeEmail(to, subject, body))
                }
                "takeNativeCrash" -> result.success(takeNativeCrash())
                else -> result.notImplemented()
            }
        }

        callRecordingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, callRecordingChannelName)
        callRecordingChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    runOnUiThread { startRecordingWatch() }
                    result.success(null)
                }
                "stop" -> {
                    runOnUiThread { stopRecordingWatch() }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, callWindowChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    runOnUiThread { setCallWindow(on) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, soundChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickSound" -> {
                    if (pendingSoundResult != null) {
                        result.error("busy", "The sound picker is already open.", null)
                        return@setMethodCallHandler
                    }
                    val current = call.argument<String>("current")
                    val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                        putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_NOTIFICATION)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "Notification sound")
                        putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, true)
                        putExtra(RingtoneManager.EXTRA_RINGTONE_DEFAULT_URI, Settings.System.DEFAULT_NOTIFICATION_URI)
                        if (!current.isNullOrEmpty()) {
                            putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, Uri.parse(current))
                        }
                    }
                    pendingSoundResult = result
                    try {
                        startActivityForResult(intent, soundRequestCode)
                    } catch (e: Exception) {
                        pendingSoundResult = null
                        result.error("unavailable", "This phone has no sound picker.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Anything that isn't ours (image picker, biometrics, ...) must still
        // reach Flutter's plugins.
        if (requestCode != soundRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingSoundResult
        pendingSoundResult = null
        if (pending == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(null) // cancelled — Dart leaves the current sound alone
            return
        }
        val uri: Uri? = if (Build.VERSION.SDK_INT >= 33) {
            data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI, Uri::class.java)
        } else {
            data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
        }
        if (uri == null) {
            // "Silent" was chosen.
            pending.success(mapOf("uri" to "", "title" to "Silent"))
            return
        }
        val title = try {
            RingtoneManager.getRingtone(this, uri)?.getTitle(this)
        } catch (e: Exception) {
            null
        }
        pending.success(mapOf("uri" to uri.toString(), "title" to (title ?: "Custom sound")))
    }

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= 34) {
            val callback = Activity.ScreenCaptureCallback {
                channel?.invokeMethod("screenshotDetected", null)
            }
            screenCaptureCallback = callback
            try {
                registerScreenCaptureCallback(mainExecutor, callback)
            } catch (e: Exception) {
                // Permission missing or the OS refused — screenshot alerts
                // simply won't fire; nothing else depends on this.
                screenCaptureCallback = null
            }
        }
    }

    override fun onStop() {
        super.onStop()
        // Feature: full-screen ringing — never stay visible over the lock screen.
        setCallWindow(false)
        if (Build.VERSION.SDK_INT >= 34) {
            screenCaptureCallback?.let {
                try {
                    unregisterScreenCaptureCallback(it)
                } catch (e: Exception) {
                    // Already unregistered — nothing to do.
                }
            }
            screenCaptureCallback = null
        }
    }
}
