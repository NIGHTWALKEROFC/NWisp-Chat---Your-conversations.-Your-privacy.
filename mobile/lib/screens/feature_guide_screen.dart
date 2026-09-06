import 'package:flutter/material.dart';

/// Distinct from OnboardingScreen (shown once, on first launch, and never
/// again) — this is a persistent reference, reachable any time from
/// Settings, for someone who wants to look something up later or a
/// returning person who skipped onboarding the first time.
class FeatureGuideScreen extends StatelessWidget {
  const FeatureGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feature guide')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _FeatureEntry(
            icon: Icons.lock_outline_rounded,
            title: 'End-to-end encryption',
            body: 'Every 1:1 and group message, photo, video, and voice note is encrypted on your '
                'device and only decrypted on the recipient\'s. The relay server never has the keys '
                'needed to read any of it.',
          ),
          _FeatureEntry(
            icon: Icons.timer_outlined,
            title: 'Disappearing messages',
            body: 'Open a chat or group\'s settings to set an auto-delete timer. Once it\'s set, new '
                'messages delete themselves after that much time — set it back to "Never" to keep '
                'everything again.',
          ),
          _FeatureEntry(
            icon: Icons.groups_outlined,
            title: 'Groups',
            body: 'Create a group from the chat list, add contacts directly, or invite anyone else '
                '(they need to accept first). Group admins can rename the group, set its description '
                'and photo, and turn on "Only admins can send messages" from group info.',
          ),
          _FeatureEntry(
            icon: Icons.phonelink_lock_outlined,
            title: 'Require approval for new logins',
            body: 'Off by default. Turn it on in Account Security and a new sign-in has to be '
                'accepted from your already-signed-in device — as a live prompt if it\'s open, or a '
                'push notification if it isn\'t — before it\'s allowed in.',
          ),
          _FeatureEntry(
            icon: Icons.devices_other_outlined,
            title: 'One device at a time',
            body: 'Signing in somewhere new signs out anywhere else automatically, so you always '
                'know exactly where your account is active. Account Security shows your recent '
                'sign-in activity.',
          ),
          _FeatureEntry(
            icon: Icons.pause_circle_outline,
            title: 'Temporarily deactivate',
            body: 'Hide your account and step away without deleting anything — from Account '
                'settings. Nobody can find or message you while deactivated; log back in any time to '
                'reactivate.',
          ),
          _FeatureEntry(
            icon: Icons.download_outlined,
            title: 'Export your data',
            body: 'Download a copy of your profile and account settings as a file, any time, from '
                'Account settings.',
          ),
          _FeatureEntry(
            icon: Icons.delete_forever_outlined,
            title: 'Delete your account',
            body: 'Permanently and irreversibly, from Account settings, with a type-to-confirm step. '
                'Removes your account, your local messages, and everything tied to it.',
          ),
          _FeatureEntry(
            icon: Icons.shield_outlined,
            title: 'Reporting and appeals',
            body: 'Report a specific rule from Community Guidelines, with optional details and a '
                'photo. Every report is reviewed by a real person — if an account is suspended, it '
                'sees the exact reason and can submit an appeal.',
          ),
          _FeatureEntry(
            icon: Icons.block_outlined,
            title: 'Blocking',
            body: 'Block anyone from their chat settings — they can no longer message you, and you '
                'won\'t see messages from them either. Unblock any time from Blocked users in '
                'Settings.',
          ),
          _FeatureEntry(
            icon: Icons.screenshot_outlined,
            title: 'Screenshot protection',
            body: 'Chats can\'t be screenshotted or screen-recorded — this is always on and isn\'t a '
                'setting you need to turn on.',
          ),
        ],
      ),
    );
  }
}

class _FeatureEntry extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _FeatureEntry({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
