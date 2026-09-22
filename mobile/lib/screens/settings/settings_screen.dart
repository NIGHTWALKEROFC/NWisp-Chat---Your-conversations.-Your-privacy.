import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../widgets/user_avatar.dart';
import '../login_screen.dart';
import 'account_screen.dart';
import 'appearance_screen.dart';
import 'chats_settings_screen.dart';
import 'edit_profile_screen.dart';
import 'help_about_screen.dart';
import 'notifications_settings_screen.dart';
import 'privacy_checkup_screen.dart';
import 'privacy_settings_screen.dart';
import 'security_settings_screen.dart';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// This used to be one long flat list mixing PIN setup, biometrics,
/// theme, last-seen, muted keywords, legal pages and more all together
/// — now it's just a clean top-level menu: tap a category, see only
/// what belongs to it, tap back out. Each category's own state/logic
/// now lives in its own screen file (security_settings_screen.dart,
/// privacy_settings_screen.dart, notifications_settings_screen.dart,
/// chats_settings_screen.dart, help_about_screen.dart) — this file only
/// owns the profile header and the menu itself.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _authService = AuthService();
  String _username = '';
  String _email = '';
  bool _loadingProfile = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final doc = await _authService.currentUserProfile();
    final data = doc.data() ?? {};
    if (!mounted) return;
    setState(() {
      _username = (data['username'] as String?) ?? '';
      _email = _authService.currentUser?.email ?? '';
      _loadingProfile = false;
    });
  }

  Future<void> _logout() async {
    await _authService.logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loadingProfile
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  leading: UserAvatar(
                    // New key whenever my photo address changes, so this
                    // avatar redraws right after I edit my profile.
                    key: ValueKey('me_${AvatarCache.instance.peek(_authService.currentUserId ?? '')}'),
                    uid: _authService.currentUserId ?? '',
                    name: _username,
                    radius: 26,
                  ),
                  title: Text(_username, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                  subtitle: Text(_email),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => EditProfileScreen(currentUsername: _username)),
                    );
                    _load();
                  },
                ),
                const Divider(height: 24),
                // Feature: Privacy checkup — a guided, WhatsApp-style walk
                // through every privacy / security setting, with a one-tap
                // "make it all as private as possible" option.
                ListTile(
                  leading: Icon(Icons.health_and_safety_outlined, color: scheme.primary),
                  title: const Text('Privacy checkup', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Check your privacy settings and turn them all on in one tap'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyCheckupScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Account'),
                  subtitle: const Text('Email, password, account security'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Privacy'),
                  subtitle: const Text('Last seen, read receipts, blocked users'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacySettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Security'),
                  subtitle: const Text('App lock, biometrics, panic PIN, chat hiding'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecuritySettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Notifications'),
                  subtitle: const Text('Muted keywords'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsSettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: const Text('Chats'),
                  subtitle: const Text('Auto-delete, paused chats, home screen layout'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatsSettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Appearance'),
                  subtitle: const Text('Customize how the app looks on this device'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearanceScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: const Text('Help & About'),
                  subtitle: const Text('Help centre, legal, feature guide'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpAboutScreen())),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: OutlinedButton.icon(
                    onPressed: _logout,
                    icon: Icon(Icons.logout, color: scheme.error),
                    label: Text('Log out', style: TextStyle(color: scheme.error)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      side: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
