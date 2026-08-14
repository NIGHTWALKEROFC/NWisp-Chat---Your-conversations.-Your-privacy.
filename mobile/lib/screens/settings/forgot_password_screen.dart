import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/contact_developer_sheet.dart';

class ForgotPasswordScreen extends StatefulWidget {
  final bool alsoResetAppLock;
  const ForgotPasswordScreen({super.key, this.alsoResetAppLock = false});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _authService = AuthService();

  final _emailController = TextEditingController();
  bool _sendingEmail = false;
  bool _emailSent = false;
  String? _emailError;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _sendingEmail = true;
      _emailError = null;
    });
    try {
      await _authService.sendPasswordResetEmail(email);
      if (widget.alsoResetAppLock) {
        await AppLockService.resetAfterAccountVerification();
      }
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _emailSent = true;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _emailError = e.message ?? 'Could not send reset email';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _emailError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("We'll email you a secure link to set a new password."),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              enabled: !_emailSent,
              decoration: const InputDecoration(labelText: 'Account email', border: OutlineInputBorder()),
            ),
            if (_emailError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_emailError!, style: TextStyle(color: scheme.error)),
              ),
            const SizedBox(height: 16),
            if (_emailSent)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.mark_email_read_outlined, color: scheme.onPrimaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Check your inbox for a reset link. It may take a minute to arrive.',
                        style: TextStyle(color: scheme.onPrimaryContainer),
                      ),
                    ),
                  ],
                ),
              )
            else
              FilledButton(
                onPressed: _sendingEmail ? null : _sendResetEmail,
                child: _sendingEmail
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send reset link'),
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextButton.icon(
            onPressed: () => showContactDeveloperSheet(context),
            icon: const Icon(Icons.support_agent_outlined, size: 18),
            label: const Text('Still stuck? Contact the developer'),
          ),
        ),
      ),
    );
  }
}
