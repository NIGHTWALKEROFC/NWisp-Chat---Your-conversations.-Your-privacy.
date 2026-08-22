import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/contact_developer_sheet.dart';
import '../login_screen.dart';
import '../security/pin_screen.dart';
import 'edit_profile_screen.dart';
import 'account_screen.dart';
import 'appearance_screen.dart';
import 'blocked_users_screen.dart';
import 'help_center_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_screen.dart';

const _ttlOptions = [0, 1, 6, 24, 72, 168]; // 0 = never auto-delete (the default)

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _authService = AuthService();
  bool _stayLoggedIn = true;
  bool _lastSeenVisible = true;
  bool _readReceiptsEnabled = true;
  bool _appLockEnabled = false;
  int _ttlHours = 0; // 0 = never auto-delete — the default; disappearing messages are opt-in
  String _username = '';
  String _email = '';
  bool _loadingProfile = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stay = await SettingsService.getStayLoggedIn();
    final appLock = await AppLockService.isEnabled();
    final doc = await _authService.currentUserProfile();
    final data = doc.data() ?? {};
    // BUGFIX: lastSeenVisible/readReceiptsEnabled/messageTtlHours moved to
    // the owner-only users/{uid}/private/profile doc (see firestore.rules)
    // so they're no longer readable by every other signed-in user.
    final privateDoc = await _authService.currentUserPrivateProfile();
    final privateData = privateDoc.data() ?? {};
    if (!mounted) return;
    setState(() {
      _stayLoggedIn = stay;
      _appLockEnabled = appLock;
      _username = (data['username'] as String?) ?? '';
      _email = _authService.currentUser?.email ?? '';
      _lastSeenVisible = (privateData['lastSeenVisible'] as bool?) ?? true;
      _readReceiptsEnabled = (privateData['readReceiptsEnabled'] as bool?) ?? true;
      _ttlHours = (privateData['messageTtlHours'] as num?)?.toInt() ?? 0;
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

  Future<void> _toggleAppLock(bool enable) async {
    if (enable) {
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)),
      );
      if (result == true && mounted) setState(() => _appLockEnabled = true);
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Turn off app lock?'),
          content: const Text('Anyone with access to your unlocked phone will be able to open this app.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Turn off'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await AppLockService.disable();
      if (mounted) setState(() => _appLockEnabled = false);
    }
  }

  void _openTtlPicker() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Auto-delete messages after', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Off by default — your messages stay on this phone until you delete them yourself. "
                  "Turning this on here sets the app-wide default; any single chat can still override it "
                  "from that chat's settings.",
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ),
            for (final hours in _ttlOptions)
              RadioListTile<int>(
                value: hours,
                groupValue: _ttlHours,
                title: Text(_ttlLabel(hours)),
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _ttlHours = value);
                  await _authService.updateMessageTtl(value);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _ttlLabel(int hours) {
    if (hours == 0) return 'Never';
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
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
                  leading: CircleAvatar(
                    radius: 26,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      _username.isNotEmpty ? _username[0].toUpperCase() : '?',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                    ),
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
                _SectionLabel('Account'),
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Account'),
                  subtitle: const Text('Email, password'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AccountScreen()),
                  ),
                ),
                _SectionLabel('Appearance'),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme & color'),
                  subtitle: const Text('Customize how the app looks on this device'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AppearanceScreen()),
                  ),
                ),
                _SectionLabel('Privacy'),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.visibility_outlined),
                  title: const Text('Show last seen'),
                  value: _lastSeenVisible,
                  onChanged: (v) async {
                    setState(() => _lastSeenVisible = v);
                    await _authService.updatePrivacySetting('lastSeenVisible', v);
                  },
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.done_all),
                  title: const Text('Read receipts'),
                  value: _readReceiptsEnabled,
                  onChanged: (v) async {
                    setState(() => _readReceiptsEnabled = v);
                    await _authService.updatePrivacySetting('readReceiptsEnabled', v);
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
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Terms & Conditions'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TermsScreen()),
                  ),
                ),
                _SectionLabel('Security'),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.pin_outlined),
                  title: const Text('App lock (PIN)'),
                  subtitle: const Text('Require a PIN every time you open the app'),
                  value: _appLockEnabled,
                  onChanged: _toggleAppLock,
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Auto-delete messages'),
                  subtitle: Text(_ttlHours == 0 ? 'Off — messages stay until you delete them' : 'After ${_ttlLabel(_ttlHours)} (app-wide default)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openTtlPicker,
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.lock_clock_outlined),
                  title: const Text('Stay signed in'),
                  subtitle: const Text('Off = sign in again every time you open the app'),
                  value: _stayLoggedIn,
                  onChanged: (v) async {
                    setState(() => _stayLoggedIn = v);
                    await SettingsService.setStayLoggedIn(v);
                  },
                ),
                _SectionLabel('Support'),
                ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: const Text('Help Centre'),
                  subtitle: const Text('FAQ and how to contact the developer'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Contact the developer'),
                  onTap: () => showContactDeveloperSheet(context),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
