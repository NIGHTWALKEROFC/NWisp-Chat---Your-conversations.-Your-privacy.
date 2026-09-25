import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Feature: CAPTCHA (Cloudflare Turnstile) — shown right before the app
/// asks the server to send a signup OTP or a password-reset code/link, so
/// scripted mass-account-creation / mass-reset-request abuse has to solve
/// a real challenge first. Cloudflare Turnstile is free at any volume on
/// the "Managed" widget mode used here.
///
/// This loads a tiny local HTML page (no domain of our own needed) into a
/// WebView, which embeds Cloudflare's own turnstile.js from
/// challenges.cloudflare.com — the ONLY network call this widget makes
/// besides that. When the widget is solved, the page calls back into Dart
/// through a JavaScript channel with the resulting token; that token is
/// then sent to the Supabase Edge Function, which verifies it server-side
/// against Cloudflare's siteverify API (see
/// supabase/functions/_shared/turnstile.ts). The token is single-use and
/// expires after 5 minutes on Cloudflare's side, so it's fetched fresh
/// immediately before each call rather than cached.
///
/// SITE KEY: Turnstile site keys are PUBLIC by design (Cloudflare's own
/// docs say they're safe to ship in client code) — only the SECRET key is
/// sensitive, and that one lives solely in Supabase's Edge Function
/// secrets, never in the app. The site key below is supplied at build
/// time via `--dart-define=TURNSTILE_SITE_KEY=...` (see codemagic.yaml),
/// with Cloudflare's own published "always passes" test key as the
/// fallback so a debug build without the dart-define still runs instead
/// of crashing.
class TurnstileCaptcha {
  /// Cloudflare's published test site key ("always passes", visible
  /// challenge). Used only if TURNSTILE_SITE_KEY isn't supplied at build
  /// time, so local `flutter run` never breaks.
  static const String _testSiteKey = '1x00000000000000000000AA';

  static const String siteKey = String.fromEnvironment(
    'TURNSTILE_SITE_KEY',
    defaultValue: _testSiteKey,
  );

  /// Shows the Turnstile challenge in a modal bottom sheet and resolves
  /// with the verification token once solved, or `null` if the person
  /// dismissed it or it failed/expired. Call this immediately before the
  /// API call that needs the token — don't store the result for later.
  static Future<String?> requestToken(BuildContext context) {
    return showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _TurnstileSheet(),
    );
  }
}

class _TurnstileSheet extends StatefulWidget {
  const _TurnstileSheet();
  @override
  State<_TurnstileSheet> createState() => _TurnstileSheetState();
}

class _TurnstileSheetState extends State<_TurnstileSheet> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;
  Timer? _timeoutTimer;

  String get _html => '''
<!DOCTYPE html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
    <style>
      html, body {
        margin: 0; padding: 0; background: transparent;
        display: flex; align-items: center; justify-content: center;
        min-height: 100vh;
      }
    </style>
  </head>
  <body>
    <div class="cf-turnstile"
         data-sitekey="${TurnstileCaptcha.siteKey}"
         data-theme="auto"
         data-callback="onTurnstileSuccess"
         data-error-callback="onTurnstileError"
         data-expired-callback="onTurnstileExpired">
    </div>
    <script>
      function onTurnstileSuccess(token) {
        TurnstileChannel.postMessage('SUCCESS:' + token);
      }
      function onTurnstileError(code) {
        TurnstileChannel.postMessage('ERROR:' + code);
      }
      function onTurnstileExpired() {
        TurnstileChannel.postMessage('EXPIRED');
      }
    </script>
  </body>
</html>
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'TurnstileChannel',
        onMessageReceived: _handleMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadHtmlString(_html, baseUrl: 'https://nwisp.app.local/');

    // Cloudflare's widget occasionally never fires any callback (e.g. no
    // network reaching challenges.cloudflare.com) — don't leave the sheet
    // stuck spinning forever.
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (mounted) setState(() => _error = "Couldn't load the security check. Check your connection and try again.");
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _handleMessage(JavaScriptMessage message) {
    final value = message.message;
    if (value.startsWith('SUCCESS:')) {
      final token = value.substring('SUCCESS:'.length);
      if (mounted) Navigator.of(context).pop(token);
    } else if (value == 'EXPIRED') {
      if (mounted) setState(() => _error = 'The check expired — please try again.');
    } else if (value.startsWith('ERROR:')) {
      if (mounted) setState(() => _error = "That didn't go through — please try again.");
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _loading = true;
    });
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (mounted) setState(() => _error = "Couldn't load the security check. Check your connection and try again.");
    });
    _controller.loadHtmlString(_html, baseUrl: 'https://nwisp.app.local/');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: 340,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Quick security check',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(null),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _error != null
                    ? _ErrorState(message: _error!, onRetry: _retry)
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          WebViewWidget(controller: _controller),
                          if (_loading) const CircularProgressIndicator(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 36, color: Colors.redAccent),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
