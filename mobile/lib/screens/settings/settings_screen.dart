import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/settings_service.dart';
import '../../services/theme_service.dart';
import '../login_screen.dart';
import 'edit_profile_screen.dart';
import 'account_screen.dart';

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
    final doc = await _authService.currentUserProfile();
    final data = doc.data() ?? {};
    if (!mounted) return;
    setState(() {
      _stayLoggedIn = stay;
      _username = (data['username'] as String?) ?? '';
      _email = _authService.currentUser?.email ?? '';
      _lastSeenVisible = (data['lastSeenVisible'] as bool?) ?? true;
      _readReceiptsEnabled = (data['readReceiptsEnabled'] as bool?) ?? true;
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

  void _openThemePicker() {
    final themeService = context.read<ThemeService>();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('App theme', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
              for (final entry in const [
                (ThemeMode.system, 'System default', Icons.brightness_auto_outlined),
                (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
              ])
                RadioListTile<ThemeMode>(
                  value: entry.$1,
                  groupValue: themeService.mode,
                  title: Text(entry.$2),
                  secondary: Icon(entry.$3),
                  onChanged: (mode) {
                    if (mode != null) themeService.setMode(mode);
                    Navigator.pop(sheetContext);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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
                  subtitle: const Text('Email, phone, password'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AccountScreen()),
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

                _SectionLabel('Appearance'),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  subtitle: Text(_themeLabel(context.watch<ThemeService>().mode)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openThemePicker,
                ),

                _SectionLabel('Session'),
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

  String _themeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System default',
      };
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
