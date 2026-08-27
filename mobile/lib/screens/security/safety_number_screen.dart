import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/safety_number_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../services/signal_session_service.dart';

/// Lets two people manually verify each other's identity out-of-band —
/// Signal calls this a "safety number", WhatsApp a "security code". If
/// the digits shown here match on both devices (compared in person, over
/// a call, or by any channel neither of you suspects is compromised),
/// that's evidence no one is silently sitting in the middle of this
/// conversation. This is the "verify before trouble" half of the app's
/// trust model — SignalSessionService's IdentityChangedException handles
/// the "react after the fact" half, for when a key changes later.
class SafetyNumberScreen extends StatefulWidget {
  final String peerUid;
  final String peerUsername;

  const SafetyNumberScreen({super.key, required this.peerUid, required this.peerUsername});

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  String? _number;
  String? _error;

  @override
  void initState() {
    super.initState();
    // This number is exactly the kind of thing that shouldn't end up
    // floating around in a screenshot — see ScreenshotGuardService.
    ScreenshotGuardService.acquire();
    _load();
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null) throw StateError('Not signed in.');
      final myKey = await SignalSessionService.instance.myIdentityPublicKeyBytes();
      final peerKey = await SignalSessionService.instance.peerIdentityPublicKeyBytes(widget.peerUid);
      if (peerKey == null) {
        if (!mounted) return;
        setState(() {
          _error =
              "Couldn't load ${widget.peerUsername}'s keys yet — send or receive at least one message with "
              "them first, then come back here.";
        });
        return;
      }
      final number = await SafetyNumberService.compute(uidA: myUid, keyA: myKey, uidB: widget.peerUid, keyB: peerKey);
      if (!mounted) return;
      setState(() => _number = number);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = "Couldn't compute a safety number right now: $e");
    }
  }

  String _formatted(String raw) {
    final groups = raw.split(' ');
    final lines = <String>[];
    for (var i = 0; i < groups.length; i += 3) {
      lines.add(groups.sublist(i, i + 3 > groups.length ? groups.length : i + 3).join('   '));
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Verify safety number')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Compare this number with ${widget.peerUsername} through a channel you both trust — read it '
                "aloud on a call, or compare side-by-side in person. If it matches on both devices, you have "
                "confirmation you're both talking directly to each other, with no one able to listen in "
                'unnoticed.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                )
              else if (_number == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.verified_user_outlined, size: 40, color: scheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        _formatted(_number!),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "This number changes if either of you reinstalls the app or switches devices — that's "
                      "expected, and you'll also see a warning right in the chat if it happens.",
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
