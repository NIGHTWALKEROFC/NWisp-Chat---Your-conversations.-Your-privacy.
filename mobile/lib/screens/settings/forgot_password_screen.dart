import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';
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

  // BUGFIX (security): this screen used to turn off App Lock the instant
  // the reset EMAIL was sent — not once the password was actually changed.
  // Since sending a reset email only requires knowing the account's email
  // address (which isn't secret), anyone with a few seconds of access to
  // an unlocked phone but a locked app could tap "Forgot PIN?" -> "I've
  // also forgotten my account password" -> type the owner's email ->
  // App Lock disabled immediately, without ever touching the owner's
  // inbox or actually resetting anything. That defeated the entire point
  // of App Lock. Now, for the "also reset app lock" flow, App Lock is only
  // disabled after we can confirm the password was genuinely changed — by
  // having the user enter the new password here and verifying it against
  // Firebase directly (same reauthenticate check the primary "Forgot PIN"
  // path already uses).
  final _newPasswordController = TextEditingController();
  bool _confirming = false;
  String? _confirmError;
  bool _appLockCleared = false;

  @override
  void dispose() {
    _emailController.dispose();
    _newPasswordController.dispose();
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

  Future<void> _confirmNewPasswordAndClearAppLock() async {
    final newPassword = _newPasswordController.text;
    if (newPassword.isEmpty) return;
    setState(() {
      _confirming = true;
      _confirmError = null;
    });
    try {
      // Only succeeds if `newPassword` really is the account's current
      // password right now — i.e. the reset link was actually used.
      await _authService.reauthenticate(newPassword);
      await AppLockService.resetAfterAccountVerification();
      final uid = _authService.currentUserId;
      if (uid != null) await DeviceSessionService.instance.logPasswordChanged(uid);
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _appLockCleared = true;
      });
    } on FirebaseAuthException catch (_) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _confirmError = "That doesn't match your current password yet — make sure you've finished the reset link first.";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _confirmError = 'Could not verify — please try again.';
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
            if (_emailSent && widget.alsoResetAppLock) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              if (_appLockCleared)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.lock_open_outlined, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'App lock turned off. Set a new PIN anytime in Settings.',
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                Text(
                  "Once you've finished the reset link, enter your new password below to also turn off App Lock.",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _newPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New account password', border: OutlineInputBorder()),
                ),
                if (_confirmError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_confirmError!, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _confirming ? null : _confirmNewPasswordAndClearAppLock,
                  child: _confirming
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Confirm & turn off App Lock'),
                ),
              ],
            ],
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
