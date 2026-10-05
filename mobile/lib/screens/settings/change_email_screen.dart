import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../widgets/confirm_email_fields.dart';

/// Change email — a full page (Instagram / Telegram style) instead of a
/// pop-up. New email + confirm, then your current password on the same page.
/// The change itself is applied the same way as before: NWisp re-checks your
/// password, then a confirmation link is sent to the NEW address.
class ChangeEmailScreen extends StatefulWidget {
  const ChangeEmailScreen({super.key});

  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final _auth = AuthService();
  final _email = TextEditingController();
  final _confirm = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  bool _sent = false;
  String? _error;

  String get _current => _auth.currentUser?.email ?? '';

  @override
  void dispose() {
    _email.dispose();
    _confirm.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _valid {
    final a = _email.text.trim();
    final b = _confirm.text.trim();
    return a.contains('@') &&
        a.contains('.') &&
        a.toLowerCase() == b.toLowerCase() &&
        a.toLowerCase() != _current.toLowerCase() &&
        _password.text.isNotEmpty;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth.reauthenticate(_password.text);
      await _auth.requestEmailChange(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not change email. Check your password and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_sent) {
      return Scaffold(
        appBar: AppBar(title: const Text('Change email')),
        body: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.mark_email_read_outlined, size: 72, color: scheme.primary),
              const SizedBox(height: 18),
              Text('Check your new inbox', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                'We sent a confirmation link to ${_email.text.trim()}. Your email changes after you open it. Until then you keep using $_current.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 26),
              FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Change email'),
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
            Text('Current email', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
            const SizedBox(height: 2),
            Text(_current, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 22),
            ConfirmEmailFields(emailController: _email, confirmController: _confirm, onChanged: () => setState(() {})),
            const SizedBox(height: 18),
            TextField(
              controller: _password,
              obscureText: _obscure,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Current password',
                helperText: 'We ask for it to make sure this is really you.',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: scheme.error))),
            const SizedBox(height: 22),
            FilledButton(onPressed: _valid && !_busy ? _submit : null, child: const Text('Send confirmation link')),
          ],
        ),
      ),
    );
  }
}
