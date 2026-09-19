import 'package:flutter/material.dart';
import '../../services/app_badge_service.dart';
import '../../services/settings_service.dart';
import 'keyword_mute_screen.dart';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// Muted keywords and the app-icon badge are the global, cross-chat
/// notification settings so far (per-chat notification
/// privacy — hiding your name/message preview from one specific
/// contact — lives in that chat's own settings instead, and the
/// GLOBAL versions of those two currently live under Account > Account
/// security). More belongs here as it gets built — this page exists so
/// there's a real "Notifications" home to add to, rather than
/// scattering future notification settings across other categories.
class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() => _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState extends State<NotificationsSettingsScreen> {
  bool _badgeEnabled = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SettingsService.getAppBadgeEnabled().then((v) {
      if (!mounted) return;
      setState(() {
        _badgeEnabled = v;
        _loading = false;
      });
    });
  }

  Future<void> _toggleBadge(bool value) async {
    setState(() => _badgeEnabled = value);
    await SettingsService.setAppBadgeEnabled(value);
    // Apply straight away — don't wait for the next message to arrive.
    await AppBadgeService.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Unread count on app icon'),
                  subtitle: const Text(
                    'Shows how many chats need you on the app icon. Hidden, muted and archived chats are never counted. '
                    'Some phones only show a dot instead of a number.',
                  ),
                  value: _badgeEnabled,
                  onChanged: _toggleBadge,
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: const Text('Muted keywords'),
                  subtitle: const Text('Messages containing these words never notify you, in any chat'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KeywordMuteScreen())),
                ),
              ],
            ),
    );
  }
}
