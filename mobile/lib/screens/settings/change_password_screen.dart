import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../widgets/breach_warning_dialog.dart';
import '../../widgets/strong_password_fields.dart';
import 'forgot_password_screen.dart';

/// Change password — a full page (Instagram / Telegram style) instead of
/// pop-ups: current password, new password + confirm, all on one page.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _auth = AuthService();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _valid => _current.text.isNotEmpty && _new.text.length >= 6 && _new.text == _confirm.text && _new.text != _current.text;

  Future<void> _submit() async {
    final ok = await confirmPasswordNotBreached(context, _new.text);
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth.reauthenticate(_current.text);
      await _auth.updatePassword(_new.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password updated')));
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Could not change password. Check your current password — or use 'Forgot password?' below.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Change password'),
        actions: [
          TextButton(
            onPressed: _valid && !_busy ? _submit : null,
            child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _current,
              obscureText: _obscure,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Current password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordScreen())),
                child: const Text('Forgot password?'),
              ),
            ),
            const SizedBox(height: 8),
            StrongPasswordFields(
              passwordController: _new,
              confirmController: _confirm,
              passwordLabel: 'New password',
              confirmLabel: 'Confirm new password',
              onChanged: () => setState(() {}),
            ),
            if (_new.text.isNotEmpty && _new.text.length < 6)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('Must be at least 6 characters.', style: TextStyle(color: scheme.error, fontSize: 12.5))),
            if (_new.text.isNotEmpty && _new.text == _current.text)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('The new password must be different.', style: TextStyle(color: scheme.error, fontSize: 12.5))),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: scheme.error))),
            const SizedBox(height: 22),
            FilledButton(onPressed: _valid && !_busy ? _submit : null, child: const Text('Change password')),
          ],
        ),
      ),
    );
  }
}
