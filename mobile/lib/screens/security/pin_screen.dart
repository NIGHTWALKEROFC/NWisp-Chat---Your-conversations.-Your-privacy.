import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';

enum PinScreenMode { setup, verify }

class PinScreen extends StatefulWidget {
  final PinScreenMode mode;
  const PinScreen({super.key, required this.mode});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }

    if (widget.mode == PinScreenMode.setup) {
      if (pin != _confirmController.text.trim()) {
        setState(() => _error = "PINs don't match");
        return;
      }
      await AppLockService.setPin(pin, hint: _hintController.text);
      if (mounted) Navigator.pop(context, true);
    } else {
      final ok = await AppLockService.verify(pin);
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
    _hintController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSetup = widget.mode == PinScreenMode.setup;
    return Scaffold(
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
                  isSetup ? 'Set an app lock PIN' : 'Enter your PIN',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _pinController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(counterText: '', labelText: 'PIN'),
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
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _hintController,
                    maxLength: 40,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      labelText: 'Optional hint (never shows your PIN)',
                      counterText: '',
                    ),
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
