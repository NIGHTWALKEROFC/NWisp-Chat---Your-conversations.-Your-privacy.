import 'package:flutter/material.dart';

/// Feature: unified voice/media UI (chat + group). Shown in place of the
/// normal compose row while a voice message is being recorded — a live
/// timer, a cancel (discard) button, and a confirm (stop + send) button.
/// Previously chat_detail_screen.dart and group_chat_screen.dart each had
/// their own slightly different version of this bar; this is the one
/// shared widget both now use.
class VoiceRecordingBar extends StatelessWidget {
  final int seconds;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  const VoiceRecordingBar({super.key, required this.seconds, required this.onCancel, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            IconButton(
              onPressed: onCancel,
              icon: Icon(Icons.delete_outline, color: scheme.error),
              tooltip: 'Cancel recording',
            ),
            Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.red)),
            const SizedBox(width: 8),
            Text('$minutes:$secs', style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('Recording voice message…', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const Spacer(),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)]),
              ),
              child: IconButton(
                onPressed: onSend,
                icon: Icon(Icons.check, color: scheme.onPrimary),
                tooltip: 'Send voice message',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
