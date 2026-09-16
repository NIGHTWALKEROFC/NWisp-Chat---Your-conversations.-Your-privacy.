import 'package:flutter/material.dart';
import 'keyword_mute_screen.dart';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// Deliberately thin right now — muted keywords is the only global,
/// cross-chat notification setting so far (per-chat notification
/// privacy — hiding your name/message preview from one specific
/// contact — lives in that chat's own settings instead, and the
/// GLOBAL versions of those two currently live under Account > Account
/// security). More belongs here as it gets built — this page exists so
/// there's a real "Notifications" home to add to, rather than
/// scattering future notification settings across other categories.
class NotificationsSettingsScreen extends StatelessWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
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
