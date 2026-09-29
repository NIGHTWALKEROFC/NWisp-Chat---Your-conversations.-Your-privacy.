package com.nightwalker.securechat

import android.app.Activity
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
    private val soundRequestCode = 4711
    private var pendingSoundResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
