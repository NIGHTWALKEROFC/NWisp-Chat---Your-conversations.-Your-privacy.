import 'package:flutter/material.dart';
import '../../services/chat_lock_service.dart';

enum HiddenChatPinScreenMode { setup, verify }

/// Mirrors PinScreen (the whole-app lock PIN) but talks to
/// ChatLockService's separate hidden-chats PIN instead of AppLockService —
/// deliberately a distinct PIN, per the feature request: someone who knows
/// (or shoulder-surfs) the app-wide unlock PIN still can't get into hidden
/// chats without also knowing this one. Optional, off by default — see
/// ChatLockSetupScreen for where it's turned on.
class HiddenChatPinScreen extends StatefulWidget {
  final HiddenChatPinScreenMode mode;
  const HiddenChatPinScreen({super.key, required this.mode});

  @override
  State<HiddenChatPinScreen> createState() => _HiddenChatPinScreenState();
}

class _HiddenChatPinScreenState extends State<HiddenChatPinScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }

    if (widget.mode == HiddenChatPinScreenMode.setup) {
      if (pin != _confirmController.text.trim()) {
        setState(() => _error = "PINs don't match");
        return;
      }
      await ChatLockService.setPin(pin);
      if (mounted) Navigator.pop(context, true);
    } else {
      final ok = await ChatLockService.verifyPin(pin);
      if (!mounted) return;
      if (ok) {
        Navigator.pop(context, true);
      } else {
        setState(() => _error = 'Incorrect PIN');
        _pinController.clear();
      }
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSetup = widget.mode == HiddenChatPinScreenMode.setup;
    return Scaffold(
      appBar: AppBar(title: Text(isSetup ? 'Set hidden-chats PIN' : 'Enter hidden-chats PIN')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pin_outlined, size: 52, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  isSetup
                      ? 'This is separate from your app lock PIN — required after a correct hide code, before hidden chats actually show.'
                      : 'Enter the PIN for hidden chats',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _pinController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  autofocus: true,
                  decoration: const InputDecoration(counterText: '', labelText: 'PIN'),
                  onSubmitted: (_) => _submit(),
                ),
                if (isSetup) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _confirmController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 8,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(counterText: '', labelText: 'Confirm PIN'),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _submit,
                  child: Text(isSetup ? 'Save PIN' : 'Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
