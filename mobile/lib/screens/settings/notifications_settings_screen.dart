import 'package:flutter/material.dart';
import '../../services/app_badge_service.dart';
import '../../services/notification_sound_service.dart';
import '../../services/quiet_hours_service.dart';
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
  QuietHours _quiet = QuietHours.defaults;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final badge = await SettingsService.getAppBadgeEnabled();
    final label = await NotificationSoundService.instance.currentSoundLabel();
    final custom = await NotificationSoundService.instance.hasCustomSound();
    final quiet = await QuietHoursService.instance.load();
    if (!mounted) return;
    setState(() {
      _badgeEnabled = badge;
      _soundLabel = label;
      _customSound = custom;
      _quiet = quiet;
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

  Future<void> _saveQuiet(QuietHours value) async {
    setState(() => _quiet = value);
    await QuietHoursService.instance.save(value);
  }

  String _timeLabel(int minutes) {
    return TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);
  }

  Future<void> _pickQuietTime({required bool start}) async {
    final current = start ? _quiet.startMin : _quiet.endMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: start ? 'Quiet hours start' : 'Quiet hours end',
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    await _saveQuiet(
      QuietHours(
        enabled: _quiet.enabled,
        startMin: start ? minutes : _quiet.startMin,
        endMin: start ? _quiet.endMin : minutes,
      ),
    );
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
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.bedtime_outlined),
                  title: const Text('Do Not Disturb'),
                  subtitle: Text(
                    _quiet.enabled
                        ? 'Message notifications are paused from ${_timeLabel(_quiet.startMin)} to ${_timeLabel(_quiet.endMin)}'
                        : 'Pause message notifications on a daily schedule',
                  ),
                  value: _quiet.enabled,
                  onChanged: (v) => _saveQuiet(QuietHours(enabled: v, startMin: _quiet.startMin, endMin: _quiet.endMin)),
                ),
                if (_quiet.enabled) ...[
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 72, right: 16),
                    title: const Text('From'),
                    trailing: Text(_timeLabel(_quiet.startMin), style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: () => _pickQuietTime(start: true),
                  ),
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 72, right: 16),
                    title: const Text('Until'),
                    trailing: Text(_timeLabel(_quiet.endMin), style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: () => _pickQuietTime(start: false),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
                    child: Text(
                      "Your messages still arrive — you'll see them when you open NWisp. "
                      'Account security alerts and incoming calls always come through.',
                      style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
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
