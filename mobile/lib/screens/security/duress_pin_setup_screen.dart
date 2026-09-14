import 'package:flutter/material.dart';
import '../../services/duress_pin_service.dart';

/// Feature: duress/panic PIN setup. Reached from Settings > Security >
/// "Panic PIN", which is itself only reachable once app lock is on and
/// the person has already gotten past the real PIN screen to open
/// Settings at all — so this screen doesn't ask for the real PIN again,
/// it just explains the feature and collects the new one (enter +
/// confirm, same shape as PinScreen's own setup mode).
class DuressPinSetupScreen extends StatefulWidget {
  const DuressPinSetupScreen({super.key});

  @override
  State<DuressPinSetupScreen> createState() => _DuressPinSetupScreenState();
}

class _DuressPinSetupScreenState extends State<DuressPinSetupScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSet = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    DuressPinService.isSet().then((v) {
      if (mounted) setState(() {
        _isSet = v;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'Use at least 4 digits');
      return;
    }
    if (pin != _confirmController.text.trim()) {
      setState(() => _error = "PINs don't match");
      return;
    }
    final ok = await DuressPinService.setPin(pin);
    if (!ok) {
      setState(() => _error = "This can't be the same as your real app-lock PIN");
      return;
    }
    if (!mounted) return;
    setState(() {
      _isSet = true;
      _error = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Panic PIN set')));
    _pinController.clear();
    _confirmController.clear();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off panic PIN?'),
        content: const Text('The decoy screen will no longer be reachable from the lock screen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Turn off')),
        ],
      ),
    );
    if (confirmed != true) return;
    await DuressPinService.clear();
    if (mounted) setState(() => _isSet = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Panic PIN')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  "A panic PIN is a second, different PIN for your lock screen. Type your REAL PIN "
                  "and you get your real chats, same as always. Type your panic PIN instead, and the "
                  "app opens to an empty, harmless-looking decoy screen instead — your real "
                  "conversations stay completely out of reach on that device, that one time.",
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                if (_isSet) ...[
                  ListTile(
                    leading: Icon(Icons.check_circle_outline, color: scheme.primary),
                    title: const Text('Panic PIN is set'),
                    subtitle: const Text("Someone forced to unlock your phone would see the decoy, not your chats"),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _clear, child: const Text('Turn off panic PIN')),
                ] else ...[
                  TextField(
                    controller: _pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 8,
                    decoration: const InputDecoration(counterText: '', labelText: 'New panic PIN'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 8,
                    decoration: const InputDecoration(counterText: '', labelText: 'Confirm panic PIN'),
                    onSubmitted: (_) => _save(),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(_error!, style: TextStyle(color: scheme.error)),
                    ),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _save, child: const Text('Set panic PIN')),
                ],
              ],
            ),
    );
  }
}
