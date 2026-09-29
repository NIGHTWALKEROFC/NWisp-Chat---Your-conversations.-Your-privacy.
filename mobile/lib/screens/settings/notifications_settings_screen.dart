import 'package:flutter/material.dart';
import '../../services/app_badge_service.dart';
import '../../services/notification_sound_service.dart';
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
  String _soundLabel = 'Default';
  bool _customSound = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final badge = await SettingsService.getAppBadgeEnabled();
    final label = await NotificationSoundService.instance.currentSoundLabel();
    final custom = await NotificationSoundService.instance.hasCustomSound();
    if (!mounted) return;
    setState(() {
      _badgeEnabled = badge;
      _soundLabel = label;
      _customSound = custom;
      _loading = false;
    });
  }

  Future<void> _pickSound() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chosen = await NotificationSoundService.instance.pickSound();
      if (chosen == null) return; // backed out
      await _load();
      messenger.showSnackBar(SnackBar(content: Text('Notification sound: $chosen')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't open the sound picker: $e")));
    }
  }

  Future<void> _resetSound() async {
    await NotificationSoundService.instance.resetToDefault();
    await _load();
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
                  leading: const Icon(Icons.music_note_outlined),
                  title: const Text('Sounds'),
                  subtitle: Text(_customSound ? _soundLabel : 'Default — tap to choose a notification sound'),
                  trailing: _customSound
                      ? TextButton(onPressed: _resetSound, child: const Text('Reset'))
                      : const Icon(Icons.chevron_right),
                  onTap: _pickSound,
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
