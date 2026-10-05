import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/languages.dart';
import '../../services/auth_service.dart';
import '../../services/nearby_service.dart';
import '../../services/locale_service.dart';
import '../../widgets/nwisp_ui.dart';
import '../../widgets/user_avatar.dart';
import '../bots/bots_hub_screen.dart';
import 'permissions_screen.dart';
import 'data_storage_screen.dart';
import 'reminders_screen.dart';
import 'backup_screen.dart';
import '../broadcast/broadcast_lists_screen.dart';
import '../browser/browser_settings_screen.dart';
import '../chat/scheduled_messages_screen.dart';
import '../chat_folders_screen.dart';
import '../login_screen.dart';
import '../notes/note_to_self_screen.dart';
import '../starred_messages_screen.dart';
import '../vault/media_vault_screen.dart';
import 'account_security_screen.dart';
import '../../services/incoming_call_notifier.dart';
import 'encryption_screen.dart';
import 'account_screen.dart';
import 'appearance_screen.dart';
import 'call_settings_screen.dart';
import 'chats_settings_screen.dart';
import 'edit_profile_screen.dart';
import 'help_about_screen.dart';
import 'language_screen.dart';
import 'notifications_settings_screen.dart';
import 'privacy_checkup_screen.dart';
import 'privacy_settings_screen.dart';
import 'report_problem_screen.dart';
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
    // Feature: Nearby chat — close any connections and forget everything.
    await NearbyService.instance.reset();
    await _authService.logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  /// One rounded, bordered block holding a few menu rows.
  Widget _group(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) children.add(const Divider(height: 1, indent: 60));
    }
    return NwispCard(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(children: children),
      ),
    );
  }

  Widget _row(IconData icon, String title, String subtitle, Widget screen) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: scheme.primary, size: 20),
      ),
      title: Text(context.tr(title), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(context.tr(subtitle), style: const TextStyle(fontSize: 12.5)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => screen)),
    );
  }

  /// A row that runs an action instead of opening a screen.
  Widget _rowAction(IconData icon, String title, String subtitle, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: scheme.primary, size: 20),
      ),
      title: Text(context.tr(title), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(context.tr(subtitle), style: const TextStyle(fontSize: 12.5)),
      onTap: onTap,
    );
  }

  /// Like [_row] but for a screen that needs its own route settings.
  Widget _rowRoute(IconData icon, String title, String subtitle, Route<void> Function() route) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: scheme.primary, size: 20),
      ),
      title: Text(context.tr(title), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(context.tr(subtitle), style: const TextStyle(fontSize: 12.5)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(context, route()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Shown under "App language": the chosen language in its own name.
    final languageName = AppLanguages.byCode(context.watch<LocaleService>().code)?.native ?? 'Phone language';
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Settings'))),
      body: _loadingProfile
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                // Profile header — centred avatar, name, email, Edit profile.
                const SizedBox(height: 8),
                Center(
                  child: GradientRing(
                    padding: 3,
                    child: UserAvatar(
                      // New key whenever my photo address changes, so this
                      // avatar redraws right after I edit my profile.
                      key: ValueKey('me_${AvatarCache.instance.peek(_authService.currentUserId ?? '')}'),
                      uid: _authService.currentUserId ?? '',
                      name: _username,
                      radius: 44,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _username,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
                ),
                const SizedBox(height: 2),
                Text(_email, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 14),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => EditProfileScreen(currentUsername: _username)),
                    );
                    _load();
                  },
                  child: Text(context.tr('Edit Profile')),
                ),
                const SizedBox(height: 18),
                // Feature: Privacy checkup — a guided, WhatsApp-style walk
                // through every privacy / security setting, with a one-tap
                // "make it all as private as possible" option.
                _group([
                  _row(Icons.health_and_safety_outlined, 'Privacy checkup', 'Check your privacy settings and turn them all on in one tap', const PrivacyCheckupScreen()),
                  _row(Icons.badge_outlined, 'Account', 'Email, password, account security', const AccountScreen()),
                  _row(Icons.lock_outline, 'Privacy', 'Last seen, read receipts, blocked users', const PrivacySettingsScreen()),
                  _row(Icons.shield_outlined, 'Security', 'App lock, biometrics, panic PIN, chat hiding', const SecuritySettingsScreen()),
                ]),
                const SizedBox(height: 14),
                // Feature: moved here from the Chats 3-dot menu.
                _group([
                  _row(Icons.enhanced_encryption_outlined, 'Encryption & quantum safety', 'Post-quantum protection, strict mode', const EncryptionScreen()),
                  _row(Icons.shield_moon_outlined, 'Private browser', 'In-app browser, tracker blocking, search engine', const BrowserSettingsScreen()),
                  _row(Icons.security_outlined, 'Login activity', 'Devices and sign-ins on your account', const AccountSecurityScreen()),
                  _rowAction(
                    Icons.phone_callback_outlined,
                    'Full-screen call alerts',
                    'Lets incoming calls ring over the lock screen, even when NWisp is closed',
                    () async {
                      final ok = await IncomingCallNotifier.requestFullScreenPermission();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok == false
                            ? 'Not allowed yet — switch on "Full-screen notifications" for NWisp in the page that opened.'
                            : 'Full-screen call alerts are allowed.'),
                      ));
                    },
                  ),
                ]),
                const SizedBox(height: 14),
                _group([
                  _row(Icons.smart_toy_outlined, 'Manage bots', 'Create and manage the bots you made', const BotsHubScreen()),
                  _row(Icons.backup_outlined, 'Backup and restore', 'Passphrase-protected copy of your chats', const BackupScreen()),
                  _row(Icons.alarm_outlined, 'Reminders', 'Messages you asked to be reminded about', const RemindersScreen()),
                  _row(Icons.data_usage_rounded, 'Data and storage', 'Auto-download rules and clearing space', const DataStorageScreen()),
                  _row(Icons.admin_panel_settings_outlined, 'Permissions', 'See, allow or turn off what NWisp can use', const PermissionsScreen()),
                  _row(Icons.campaign_outlined, 'Broadcast lists', 'Send one message to many people', const BroadcastListsScreen()),
                  _row(Icons.folder_outlined, 'Chat folders', 'Organise your chats', const ChatFoldersScreen()),
                  _row(Icons.edit_note, 'Note to self', 'A private notepad on this phone', const NoteToSelfScreen()),
                  _row(Icons.schedule, 'Scheduled messages', 'Messages waiting to be sent', const ScheduledMessagesScreen()),
                  _row(Icons.star_border, 'Starred messages', 'Messages you starred', const StarredMessagesScreen()),
                  _rowRoute(
                    Icons.enhanced_encryption_outlined,
                    'Media vault',
                    'Locked photos and videos',
                    () => MaterialPageRoute<void>(settings: const RouteSettings(name: '/vault'), builder: (_) => const MediaVaultScreen()),
                  ),
                ]),
                const SizedBox(height: 14),
                _group([
                  _row(Icons.call_outlined, 'Calls', 'Protect your IP address in calls', const CallSettingsScreen()),
                ]),
                const SizedBox(height: 14),
                _group([
                  _row(Icons.language, 'App language', languageName, const LanguageScreen()),
                ]),
                const SizedBox(height: 14),
                _group([
                  _row(Icons.notifications_outlined, 'Notifications', 'Muted keywords', const NotificationsSettingsScreen()),
                  _row(Icons.chat_bubble_outline, 'Chats', 'Auto-delete, paused chats, home screen layout', const ChatsSettingsScreen()),
                  _row(Icons.palette_outlined, 'Appearance', 'Customize how the app looks on this device', const AppearanceScreen()),
                ]),
                const SizedBox(height: 14),
                _group([
                  _row(Icons.bug_report_outlined, 'Report a problem', 'Report a bug or a security problem', const ReportProblemScreen()),
                ]),
                const SizedBox(height: 14),
                _group([
                  _row(Icons.help_outline, 'Help & About', 'Help centre, legal, feature guide', const HelpAboutScreen()),
                ]),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _logout,
                  icon: Icon(Icons.logout, color: scheme.error),
                  label: Text(context.tr('Log out'), style: TextStyle(color: scheme.error)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    side: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
                  ),
                ),
              ],
            ),
    );
  }
}
