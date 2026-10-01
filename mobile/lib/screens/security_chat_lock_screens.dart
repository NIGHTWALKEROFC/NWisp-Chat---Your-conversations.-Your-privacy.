import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/biometric_unlock_service.dart';
import '../services/security_chat_lock_service.dart';

/// Screens and dialogs for the optional lock on "NWisp Chat Notifications".
/// See SecurityChatLockService for what this lock is (and isn't).

const _minPinLength = 4;
const _maxPinLength = 6;

InputDecoration _pinDecoration(String label) => InputDecoration(labelText: label, counterText: '');

/// Shown once, the first time the notifications chat is opened. Returns true
/// if the person chose to set a lock up (and finished doing it).
Future<bool> showSecurityChatLockOffer(BuildContext context) async {
  final wantsIt = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 40, color: scheme.primary),
              const SizedBox(height: 12),
              const Text('Lock this chat?', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'This chat shows your devices and sign-in locations. You can protect just this chat with a PIN '
                "(and your fingerprint or face, if your phone has it). Your app and your other chats aren't affected.\n\n"
                'You can also turn this on later in Settings > Security, or with the lock button in this chat.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(sheetContext, true), child: const Text('Set up lock')),
              ),
              TextButton(onPressed: () => Navigator.pop(sheetContext, false), child: const Text('Not now')),
            ],
          ),
        ),
      );
    },
  );
  if (wantsIt != true || !context.mounted) return false;
  final done = await Navigator.push<bool>(
    context,
    MaterialPageRoute(builder: (_) => const SecurityChatPinSetupScreen()),
  );
  return done == true;
}

/// Asks for the current PIN (or biometrics) before something sensitive, like
/// turning the lock off or changing the PIN. Returns true when it passes.
Future<bool> confirmSecurityChatLock(BuildContext context) async {
  final ok = await showDialog<bool>(context: context, builder: (_) => const _ConfirmLockDialog());
  return ok == true;
}

class _ConfirmLockDialog extends StatefulWidget {
  const _ConfirmLockDialog();

  @override
  State<_ConfirmLockDialog> createState() => _ConfirmLockDialogState();
}

class _ConfirmLockDialogState extends State<_ConfirmLockDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _biometric = false;

  @override
  void initState() {
    super.initState();
    SecurityChatLockService.instance.isBiometricEnabled().then((on) {
      if (mounted) setState(() => _biometric = on);
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final service = SecurityChatLockService.instance;
    final left = service.lockoutRemaining;
    if (left != null) {
      setState(() => _error = 'Too many tries. Wait ${left.inSeconds + 1}s.');
      return;
    }
    if (await service.verifyPin(_pin.text.trim())) {
      if (mounted) Navigator.pop(context, true);
    } else if (mounted) {
      setState(() => _error = 'Wrong PIN');
      _pin.clear();
    }
  }

  Future<void> _useBiometric() async {
    final ok = await BiometricUnlockService.authenticate(reason: 'Confirm it\'s you');
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter your PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: _maxPinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _pinDecoration('PIN').copyWith(errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          if (_biometric)
            TextButton.icon(
              onPressed: _useBiometric,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Use biometrics'),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Confirm')),
      ],
    );
  }
}

/// Choose a PIN (and optionally biometrics) and turn the lock on. Pops true
/// when the lock was saved.
class SecurityChatPinSetupScreen extends StatefulWidget {
  const SecurityChatPinSetupScreen({super.key});

  @override
  State<SecurityChatPinSetupScreen> createState() => _SecurityChatPinSetupScreenState();
}

class _SecurityChatPinSetupScreenState extends State<SecurityChatPinSetupScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _biometricAvailable = false;
  bool _useBiometric = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    BiometricUnlockService.isAvailable().then((ok) {
      if (mounted) setState(() => _biometricAvailable = ok);
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pin = _pin.text.trim();
    if (pin.length < _minPinLength) {
      setState(() => _error = 'Use at least $_minPinLength digits.');
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = "The two PINs don't match.");
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var biometric = false;
    if (_biometricAvailable && _useBiometric) {
      // Prove it works once now, so the person isn't locked into a biometric
      // setting that then fails every time. The PIN is saved either way.
      biometric = await BiometricUnlockService.authenticate(reason: 'Turn on biometrics for NWisp Chat Notifications');
      if (!biometric && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Biometrics weren't confirmed, so only the PIN is on. You can turn them on later.")),
        );
      }
    }
    await SecurityChatLockService.instance.enable(pin, biometric: biometric);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Lock NWisp Chat Notifications')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Choose a PIN for this chat only. It is separate from your app lock — your app and other chats '
            "won't ask for it.",
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: _maxPinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _pinDecoration('PIN ($_minPinLength–$_maxPinLength digits)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: _maxPinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _pinDecoration('Confirm PIN'),
          ),
          if (_biometricAvailable)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also use fingerprint / face'),
              subtitle: const Text('A faster way in. The PIN still works if it fails.'),
              value: _useBiometric,
              onChanged: (v) => setState(() => _useBiometric = v),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('Turn on lock'),
          ),
          const SizedBox(height: 12),
          Text(
            'Forgot the PIN later? You can reset it by entering your account password.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// What the notifications chat shows instead of its messages while it's
/// locked. Calls [onUnlocked] when the PIN (or biometrics) pass.
class SecurityChatUnlockGate extends StatefulWidget {
  final VoidCallback onUnlocked;
  const SecurityChatUnlockGate({super.key, required this.onUnlocked});

  @override
  State<SecurityChatUnlockGate> createState() => _SecurityChatUnlockGateState();
}

class _SecurityChatUnlockGateState extends State<SecurityChatUnlockGate> {
  final _pin = TextEditingController();
  String? _error;
  bool _biometric = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final on = await SecurityChatLockService.instance.isBiometricEnabled();
    final available = on && await BiometricUnlockService.isAvailable();
    if (!mounted) return;
    setState(() => _biometric = available);
    if (available) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final ok = await BiometricUnlockService.authenticate(reason: 'Unlock NWisp Chat Notifications');
    if (ok && mounted) widget.onUnlocked();
  }

  Future<void> _submit() async {
    final service = SecurityChatLockService.instance;
    final left = service.lockoutRemaining;
    if (left != null) {
      setState(() => _error = 'Too many tries. Wait ${left.inSeconds + 1}s.');
      return;
    }
    if (await service.verifyPin(_pin.text.trim())) {
      if (mounted) widget.onUnlocked();
    } else if (mounted) {
      setState(() => _error = 'Wrong PIN');
      _pin.clear();
    }
  }

  /// Forgot the PIN: proving the account password turns the lock off, so
  /// nobody is ever locked out of their own account alerts for good.
  Future<void> _forgotPin() async {
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(
          builder: (dialogContext, setLocal) => AlertDialog(
            title: const Text('Reset the lock'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Enter your account password. This turns the lock off — you can set a new one afterwards.'),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(labelText: 'Account password', errorText: error),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  try {
                    await AuthService().reauthenticate(password.text);
                    if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                  } catch (_) {
                    setLocal(() => error = 'That password is not right.');
                  }
                },
                child: const Text('Reset'),
              ),
            ],
          ),
        );
      },
    );
    password.dispose();
    if (ok == true) {
      await SecurityChatLockService.instance.disable();
      if (mounted) widget.onUnlocked();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 48, color: scheme.primary),
            const SizedBox(height: 14),
            const Text('This chat is locked', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: TextField(
                controller: _pin,
                obscureText: true,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                maxLength: _maxPinLength,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _pinDecoration('PIN').copyWith(errorText: _error),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _submit, child: const Text('Unlock')),
            if (_biometric)
              TextButton.icon(
                onPressed: _tryBiometric,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Use biometrics'),
              ),
            TextButton(onPressed: _forgotPin, child: const Text('Forgot PIN?')),
          ],
        ),
      ),
    );
  }
}

/// Settings > Security > NWisp Chat Notifications lock, and the lock button
/// inside the chat itself — both open this.
class SecurityChatLockSettingsScreen extends StatefulWidget {
  const SecurityChatLockSettingsScreen({super.key});

  @override
  State<SecurityChatLockSettingsScreen> createState() => _SecurityChatLockSettingsScreenState();
}

class _SecurityChatLockSettingsScreenState extends State<SecurityChatLockSettingsScreen> {
  final _service = SecurityChatLockService.instance;
  bool _loading = true;
  bool _enabled = false;
  bool _biometric = false;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _service.isEnabled();
    final biometric = await _service.isBiometricEnabled();
    final available = await BiometricUnlockService.isAvailable();
    await _service.load();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _biometric = biometric;
      _biometricAvailable = available;
      _loading = false;
    });
  }

  Future<void> _toggleLock(bool turnOn) async {
    if (turnOn) {
      await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const SecurityChatPinSetupScreen()));
    } else {
      if (!await confirmSecurityChatLock(context)) return;
      await _service.disable();
    }
    await _load();
  }

  Future<void> _toggleBiometric(bool turnOn) async {
    if (turnOn) {
      final ok = await BiometricUnlockService.authenticate(reason: 'Turn on biometrics for NWisp Chat Notifications');
      if (!ok) return;
    }
    await _service.setBiometricEnabled(turnOn);
    await _load();
  }

  Future<void> _changePin() async {
    if (!await confirmSecurityChatLock(context)) return;
    if (!mounted) return;
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const SecurityChatPinSetupScreen()));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('NWisp Chat Notifications lock')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Ask for a PIN before opening your account alerts. This only protects that chat — your app lock and '
                    'your other chats are not affected.',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5, height: 1.4),
                  ),
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.lock_outline),
                  title: const Text('Lock this chat'),
                  subtitle: Text(_enabled ? 'On — asks for your PIN every time it opens' : 'Off'),
                  value: _enabled,
                  onChanged: _toggleLock,
                ),
                if (_enabled && _biometricAvailable)
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.fingerprint),
                    title: const Text('Use fingerprint / face'),
                    subtitle: const Text('A faster way in. The PIN still works as a backup.'),
                    value: _biometric,
                    onChanged: _toggleBiometric,
                  ),
                if (_enabled)
                  ListTile(
                    leading: const Icon(Icons.password_outlined),
                    title: const Text('Change PIN'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _changePin,
                  ),
              ],
            ),
    );
  }
}
