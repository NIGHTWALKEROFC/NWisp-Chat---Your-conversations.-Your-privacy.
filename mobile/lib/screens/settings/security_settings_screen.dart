import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/biometric_unlock_service.dart';
import '../../services/settings_service.dart';
import '../security/duress_pin_setup_screen.dart';
import '../security/pin_screen.dart';
import 'chat_lock_setup_screen.dart';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// Everything about locking the app/hiding chats/wiping inactive data,
/// pulled out of the old single flat settings_screen.dart list — tap
/// "Security" from the main Settings menu, see only this, tap back out.
class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  bool _appLockEnabled = false;
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;
  int? _idleTimeoutMinutes;
  bool _inactivityWipeEnabled = false;
  int _inactivityWipeMonths = 3;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final appLock = await AppLockService.isEnabled();
    final biometricEnabled = await AppLockService.isBiometricEnabled();
    final biometricAvailable = await BiometricUnlockService.isAvailable();
    final idleTimeoutMinutes = await AppLockService.getIdleTimeoutMinutes();
    final inactivityWipeEnabled = await SettingsService.getInactivityWipeGlobalEnabled();
    final inactivityWipeMonths = await SettingsService.getInactivityWipeGlobalMonths();
    if (!mounted) return;
    setState(() {
      _appLockEnabled = appLock;
      _biometricEnabled = biometricEnabled;
      _biometricAvailable = biometricAvailable;
      _idleTimeoutMinutes = idleTimeoutMinutes;
      _inactivityWipeEnabled = inactivityWipeEnabled;
      _inactivityWipeMonths = inactivityWipeMonths;
      _loading = false;
    });
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
      if (mounted) setState(() {
        _appLockEnabled = false;
        _biometricEnabled = false;
        _idleTimeoutMinutes = null;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    await AppLockService.setBiometricEnabled(value);
    if (mounted) setState(() => _biometricEnabled = value);
  }

  Future<void> _pickIdleTimeout() async {
    const offSentinel = 0;
    final options = <int, String>{
      offSentinel: 'Off',
      1: '1 minute',
      2: '2 minutes',
      5: '5 minutes',
      15: '15 minutes',
    };
    final current = _idleTimeoutMinutes ?? offSentinel;
    final picked = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Auto-lock after inactivity'),
        children: options.entries.map((e) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, e.key),
            child: Row(
              children: [
                Icon(current == e.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                const SizedBox(width: 12),
                Text(e.value),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (picked == null) return;
    final minutes = picked == offSentinel ? null : picked;
    await AppLockService.setIdleTimeoutMinutes(minutes);
    if (mounted) setState(() => _idleTimeoutMinutes = minutes);
  }

  Future<void> _pickInactivityWipeMonths() async {
    final options = [1, 2, 3, 6, 12];
    final picked = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Auto-wipe after how long'),
        children: options.map((m) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, m),
            child: Row(
              children: [
                Icon(_inactivityWipeMonths == m ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                const SizedBox(width: 12),
                Text('$m month${m == 1 ? '' : 's'}'),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (picked == null) return;
    await SettingsService.setInactivityWipeGlobalMonths(picked);
    if (mounted) setState(() => _inactivityWipeMonths = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.pin_outlined),
                  title: const Text('App lock (PIN)'),
                  subtitle: const Text('Require a PIN every time you open the app'),
                  value: _appLockEnabled,
                  onChanged: _toggleAppLock,
                ),
                if (_appLockEnabled && _biometricAvailable)
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.fingerprint),
                    title: const Text('Unlock with biometrics'),
                    subtitle: const Text('Face/fingerprint as a shortcut for your PIN — the PIN itself still always works too'),
                    value: _biometricEnabled,
                    onChanged: _toggleBiometric,
                  ),
                if (_appLockEnabled)
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Auto-lock after inactivity'),
                    subtitle: Text(
                      _idleTimeoutMinutes == null
                          ? 'Off — only re-locks when you leave the app'
                          : 'Locks after $_idleTimeoutMinutes minute${_idleTimeoutMinutes == 1 ? '' : 's'} of no activity, even if the app stays open',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickIdleTimeout,
                  ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Panic PIN'),
                  subtitle: Text(
                    _appLockEnabled
                        ? 'A second PIN that opens a decoy screen instead of your real chats'
                        : 'Set up App lock (PIN) above first — a panic PIN only makes sense once you have a real PIN',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (!_appLockEnabled) {
                      showDialog(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Set up App lock first'),
                          content: const Text(
                            "A panic PIN needs a real PIN to be different FROM — turn on App lock (PIN) above, then come back here.",
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                            FilledButton(
                              onPressed: () {
                                Navigator.pop(dialogContext);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)))
                                    .then((_) => _load());
                              },
                              child: const Text('Set up PIN'),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DuressPinSetupScreen()),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Chat hiding'),
                  subtitle: const Text('Hide specific chats behind a password or emoji code'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ChatLockSetupScreen()),
                  ),
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.auto_delete_outlined),
                  title: const Text('Auto-wipe inactive chats'),
                  subtitle: Text(
                    _inactivityWipeEnabled
                        ? "On — any chat not opened in $_inactivityWipeMonths month${_inactivityWipeMonths == 1 ? '' : 's'} clears itself from this device (a chat can still opt out from its own settings)"
                        : "Off by default — a chat not opened for a long time stays exactly as it is, unless you turn this on here or for one specific chat from that chat's own settings",
                  ),
                  value: _inactivityWipeEnabled,
                  onChanged: (v) async {
                    setState(() => _inactivityWipeEnabled = v);
                    await SettingsService.setInactivityWipeGlobalEnabled(v);
                  },
                ),
                if (_inactivityWipeEnabled)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 72, right: 16),
                    title: const Text('After how long'),
                    subtitle: Text('$_inactivityWipeMonths month${_inactivityWipeMonths == 1 ? '' : 's'} of not opening a chat'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickInactivityWipeMonths,
                  ),
              ],
            ),
    );
  }
}
