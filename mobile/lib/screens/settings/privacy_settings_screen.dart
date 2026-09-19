import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/private_keyboard_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../services/settings_service.dart';
import 'blocked_users_screen.dart';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// Who can see your last-seen/read-receipts, and who you've blocked —
/// pulled out of the old flat settings_screen.dart list. Notification-
/// specific privacy (hiding your name/message preview) lives under
/// Account > Account security instead, since it's about notifications
/// specifically rather than general privacy — this page can grow with
/// more general privacy controls later.
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  final _authService = AuthService();
  bool _lastSeenVisible = true;
  bool _readReceiptsEnabled = true;
  bool _hideRecentsPreview = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final privateDoc = await _authService.currentUserPrivateProfile();
    final privateData = privateDoc.data() ?? {};
    final hideRecents = await SettingsService.getHideRecentsPreview();
    if (!mounted) return;
    setState(() {
      _hideRecentsPreview = hideRecents;
      _lastSeenVisible = (privateData['lastSeenVisible'] as bool?) ?? true;
      _readReceiptsEnabled = (privateData['readReceiptsEnabled'] as bool?) ?? true;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.visibility_outlined),
                  title: const Text('Show last seen'),
                  subtitle: const Text('Can be hidden from one specific person instead, from that chat\'s own settings'),
                  value: _lastSeenVisible,
                  onChanged: (v) async {
                    setState(() => _lastSeenVisible = v);
                    await _authService.updatePrivacySetting('lastSeenVisible', v);
                  },
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.done_all),
                  title: const Text('Read receipts'),
                  subtitle: const Text('Can be hidden from one specific person instead, from that chat\'s own settings'),
                  value: _readReceiptsEnabled,
                  onChanged: (v) async {
                    setState(() => _readReceiptsEnabled = v);
                    await _authService.updatePrivacySetting('readReceiptsEnabled', v);
                  },
                ),
                // Feature: private keyboard mode (OFF by default).
                ValueListenableBuilder<bool>(
                  valueListenable: PrivateKeyboardService.enabled,
                  builder: (context, on, _) => SwitchListTile.adaptive(
                    secondary: const Icon(Icons.keyboard_alt_outlined),
                    title: const Text('Private keyboard'),
                    subtitle: const Text(
                      'Asks your keyboard not to learn from what you type here, and to turn off suggestions and auto-correct. '
                      'Most keyboards, like Gboard, honour this.',
                    ),
                    value: on,
                    onChanged: PrivateKeyboardService.setEnabled,
                  ),
                ),
                // Feature: hide the app preview in the recent-apps switcher.
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Hide app preview in recent apps'),
                  subtitle: const Text(
                    'The app shows up blank when you look at your recent apps. On Android 12 and older this also blocks '
                    'screenshots everywhere in the app. Chats are always screenshot-protected either way.',
                  ),
                  value: _hideRecentsPreview,
                  onChanged: (v) async {
                    setState(() => _hideRecentsPreview = v);
                    await SettingsService.setHideRecentsPreview(v);
                    await ScreenshotGuardService.setRecentsPreviewHidden(v);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.block_outlined),
                  title: const Text('Blocked users'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
                  ),
                ),
              ],
            ),
    );
  }
}
