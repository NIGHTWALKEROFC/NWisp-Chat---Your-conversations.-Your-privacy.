package com.nightwalker.securechat

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
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.nightwalker.securechat/screenshot_guard"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
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
                else -> result.notImplemented()
            }
        }
    }
}
