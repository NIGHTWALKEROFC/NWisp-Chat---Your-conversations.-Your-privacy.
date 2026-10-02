import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/biometric_unlock_service.dart';
import '../../services/intruder_photo_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/duration_picker_dialog.dart';
import '../security/duress_pin_setup_screen.dart';
import '../security/pin_screen.dart';
import '../security_chat_lock_screens.dart';
import 'chat_lock_setup_screen.dart';
import 'intruder_photo_screen.dart';

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
  // Feature: lock timing when leaving the app. 0 = immediately (default).
  int _graceMinutes = 0;
  // Feature: shake to lock (off by default).
  bool _shakeToLock = false;
  // Feature: intruder photo (off by default).
  bool _intruderPhoto = false;
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
    final graceMinutes = await AppLockService.getBackgroundGraceMinutes();
    final shakeToLock = await AppLockService.getShakeToLockEnabled();
    final intruderPhoto = await IntruderPhotoService.instance.isEnabled();
    final inactivityWipeEnabled = await SettingsService.getInactivityWipeGlobalEnabled();
    final inactivityWipeMonths = await SettingsService.getInactivityWipeGlobalMonths();
    if (!mounted) return;
    setState(() {
      _appLockEnabled = appLock;
      _biometricEnabled = biometricEnabled;
      _biometricAvailable = biometricAvailable;
      _idleTimeoutMinutes = idleTimeoutMinutes;
      _graceMinutes = graceMinutes;
      _shakeToLock = shakeToLock;
      _intruderPhoto = intruderPhoto;
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
        _graceMinutes = 0;
        _shakeToLock = false;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    await AppLockService.setBiometricEnabled(value);
    if (mounted) setState(() => _biometricEnabled = value);
  }

  /// Shared picker for both lock-timing settings below: a list of ready-made
  /// choices (minutes -> label) plus a "Custom…" row that opens the
  /// number-and-unit dialog. Returns the chosen number of MINUTES, or null if
  /// the person backed out. [current] is highlighted, and if it isn't one of
  /// the ready-made choices the Custom row shows it as the selected value.
  Future<int?> _pickMinutes({
    required String title,
    required Map<int, String> presets,
    required int current,
    required String customTitle,
    String? customHelper,
  }) async {
    const customSentinel = -1;
    final isCustomCurrent = !presets.containsKey(current);
    final choice = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          for (final e in presets.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, e.key),
              child: Row(
                children: [
                  Icon(current == e.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                  const SizedBox(width: 12),
                  Text(e.value),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, customSentinel),
            child: Row(
              children: [
                Icon(isCustomCurrent ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                const SizedBox(width: 12),
                Text(isCustomCurrent ? 'Custom (${formatDuration(Duration(minutes: current))})' : 'Custom…'),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null) return null;
    if (choice != customSentinel) return choice;
    if (!mounted) return null;
    final d = await showCustomDurationDialog(
      context,
      title: customTitle,
      helperText: customHelper,
      units: const [DurationUnit.minutes, DurationUnit.hours],
      initialUnit: DurationUnit.minutes,
      initialValue: isCustomCurrent ? current : 10,
      min: const Duration(minutes: 1),
      max: const Duration(hours: 24),
    );
    return d?.inMinutes;
  }

  /// Feature: lock timing when LEAVING the app — Immediately / 1 minute /
  /// 5 minutes / 15 minutes / 1 hour / Custom. "Immediately" is the default
  /// and the strictest (the app's original behaviour).
  Future<void> _pickBackgroundGrace() async {
    final picked = await _pickMinutes(
      title: 'Lock when I leave the app',
      presets: const {
        0: 'Immediately',
        1: 'After 1 minute',
        5: 'After 5 minutes',
        15: 'After 15 minutes',
        60: 'After 1 hour',
      },
      current: _graceMinutes,
      customTitle: 'Lock after…',
      customHelper: 'How long the app can sit in the background before it asks for your PIN again.',
    );
    if (picked == null) return;
    await AppLockService.setBackgroundGraceMinutes(picked);
    if (mounted) setState(() => _graceMinutes = picked);
  }

  /// Lock after a stretch of no touching while the app stays OPEN. 0 = off.
  Future<void> _pickIdleTimeout() async {
    final picked = await _pickMinutes(
      title: 'Auto-lock after inactivity',
      presets: const {
        0: 'Off',
        1: '1 minute',
        2: '2 minutes',
        5: '5 minutes',
        15: '15 minutes',
        30: '30 minutes',
        60: '1 hour',
      },
      current: _idleTimeoutMinutes ?? 0,
      customTitle: 'Lock after inactivity of…',
      customHelper: 'The app locks itself after this long without you touching the screen.',
    );
    if (picked == null) return;
    final minutes = picked == 0 ? null : picked;
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
                // Feature: shake to lock. The Lock now button on the chat
                // list works with or without this.
                if (_appLockEnabled)
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.vibration),
                    title: const Text('Shake to lock'),
                    subtitle: const Text('Shake your phone firmly to lock the app instantly, from anywhere in it'),
                    value: _shakeToLock,
                    onChanged: (v) async {
                      setState(() => _shakeToLock = v);
                      await AppLockService.setShakeToLockEnabled(v);
                    },
                  ),
                if (_appLockEnabled)
                  ListTile(
                    leading: const Icon(Icons.lock_clock_outlined),
                    title: const Text('Lock when I leave the app'),
                    subtitle: Text(
                      _graceMinutes <= 0
                          ? 'Immediately — asks for your PIN as soon as you switch away'
                          : 'Asks for your PIN after ${formatDuration(Duration(minutes: _graceMinutes))} away from the app',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickBackgroundGrace,
                  ),
                if (_appLockEnabled)
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Auto-lock after inactivity'),
                    subtitle: Text(
                      _idleTimeoutMinutes == null
                          ? 'Off — the app stays unlocked while it is open'
                          : 'Locks after ${formatDuration(Duration(minutes: _idleTimeoutMinutes!))} of no activity, even if the app stays open',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickIdleTimeout,
                  ),
                // Feature: intruder photo — front-camera photo after wrong
                // PINs, saved in the vault. Off by default; needs App lock.
                if (_appLockEnabled)
                  ListTile(
                    leading: const Icon(Icons.no_photography_outlined),
                    title: const Text('Intruder photo'),
                    subtitle: Text(
                      _intruderPhoto
                          ? 'On — a photo is taken after wrong PINs and saved in your Media vault'
                          : 'Off — take a photo of anyone who enters wrong PINs',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const IntruderPhotoScreen())).then((_) => _load()),
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
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Lock NWisp Chat Notifications'),
                  subtitle: const Text('Ask for a PIN or biometrics before opening your account alerts'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SecurityChatLockSettingsScreen()),
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
