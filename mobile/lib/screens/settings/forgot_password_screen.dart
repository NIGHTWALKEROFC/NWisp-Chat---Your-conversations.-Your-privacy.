import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';
import '../../widgets/contact_developer_sheet.dart';
import '../../widgets/breach_warning_dialog.dart';
import '../../widgets/strong_password_fields.dart';

class ForgotPasswordScreen extends StatefulWidget {
  final bool alsoResetAppLock;

  /// Set when this screen is opened from WITHIN an already-signed-in
  /// account (Account Security -> "Not sure this was you?") — we
  /// already know this account's email in that case, so there's no
  /// reason to make the person type it again. When null (the normal
  /// pre-login "Forgot password?" entry point), the person types
  /// either their email OR their username.
  final String? knownEmail;

  const ForgotPasswordScreen({super.key, this.alsoResetAppLock = false, this.knownEmail});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _authService = AuthService();

  late final _identifierController = TextEditingController(text: widget.knownEmail ?? '');
  bool get _identifierIsFixed => widget.knownEmail != null;

  bool _sendingEmail = false;
  bool _emailSent = false;
  String? _emailError;

  // Feature: the account being reset may have opted into OTP-based
  // reset (Settings -> Account security -> "Password reset method")
  // instead of the emailed link — the server decides which one actually
  // happened and tells us via `mode`, since this screen has no way to
  // know in advance (it's asked before anyone's signed in).
  String? _mode; // 'email' | 'otp', set once a request succeeds

  // ---- OTP-mode state ----
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmNewPasswordController = TextEditingController();
  bool _otpConfirmedFormat = false; // just "looks like 6 digits", not server-verified yet
  bool _resettingViaOtp = false;
  String? _otpError;
  bool _otpResetDone = false;
  int _resendCooldown = 0;
  Timer? _resendTimer;

  // BUGFIX (security): this screen used to turn off App Lock the instant
  // the reset EMAIL was sent — not once the password was actually changed.
  // Since sending a reset email only requires knowing the account's email
  // address (which isn't secret), anyone with a few seconds of access to
  // an unlocked phone but a locked app could tap "Forgot PIN?" -> "I've
  // also forgotten my account password" -> type the owner's email ->
  // App Lock disabled immediately, without ever touching the owner's
  // inbox or actually resetting anything. That defeated the entire point
  // of App Lock. Now, for the "also reset app lock" flow:
  //   - email mode: App Lock only clears after the person enters the
  //     NEW password here and we verify it against Firebase directly
  //     (reauthenticate) — proving the reset link was actually used.
  //   - otp mode: we already directly set the new password ourselves
  //     server-side the moment verify-password-reset-otp succeeds, so
  //     there's nothing left to "prove" — App Lock clears immediately
  //     on that success.
  final _newPasswordConfirmController = TextEditingController();
  bool _confirming = false;
  String? _confirmError;
  bool _appLockCleared = false;

  @override
  void dispose() {
    _identifierController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmNewPasswordController.dispose();
    _newPasswordConfirmController.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendCooldown = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendCooldown--;
        if (_resendCooldown <= 0) timer.cancel();
      });
    });
  }

  Future<void> _sendResetEmail() async {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty) return;
    setState(() {
      _sendingEmail = true;
      _emailError = null;
    });
    try {
      final result = await _authService.requestPasswordReset(identifier);
      if (!mounted) return;
      final mode = (result['mode'] as String?) ?? 'email';
      setState(() {
        _sendingEmail = false;
        _emailSent = true;
        _mode = mode;
      });
      if (mode == 'otp') _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        // Includes the "No account found with that email or username."
        // case — this screen deliberately shows that outright rather
        // than a generic "check your email" either way. See
        // AuthService.requestPasswordReset's doc comment for why.
        _emailError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _resendOtp() async {
    if (_resendCooldown > 0) return;
    setState(() {
      _sendingEmail = true;
      _otpError = null;
    });
    try {
      await _authService.requestPasswordReset(_identifierController.text.trim());
      if (!mounted) return;
      setState(() => _sendingEmail = false);
      _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _otpError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _submitOtpReset() async {
    final code = _otpController.text.trim();
    final newPassword = _newPasswordController.text;
    setState(() => _otpError = null);
    if (code.length != 6) {
      setState(() => _otpError = 'Enter the 6-digit code from your email.');
      return;
    }
    if (newPassword.length < 6) {
      setState(() => _otpError = 'Password must be at least 6 characters.');
      return;
    }
    if (newPassword != _confirmNewPasswordController.text) {
      setState(() => _otpError = "Passwords don't match.");
      return;
    }
    final ok = await confirmPasswordNotBreached(context, newPassword);
    if (!ok || !mounted) return;
    setState(() => _resettingViaOtp = true);
    try {
      await _authService.verifyPasswordResetOtp(
        email: _identifierController.text.trim(),
        code: code,
        newPassword: newPassword,
      );
      if (!mounted) return;
      _resendTimer?.cancel();
      setState(() {
        _resettingViaOtp = false;
        _otpResetDone = true;
      });
      // We just set the new password ourselves server-side, so — unlike
      // the email-link flow — there's nothing left to prove before
      // clearing App Lock; do it immediately if that's why we're here.
      if (widget.alsoResetAppLock) {
        final uid = _authService.currentUserId;
        await AppLockService.resetAfterAccountVerification();
        if (uid != null) await DeviceSessionService.instance.logPasswordChanged(uid);
        if (mounted) setState(() => _appLockCleared = true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resettingViaOtp = false;
        _otpError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _confirmNewPasswordAndClearAppLock() async {
    final newPassword = _newPasswordConfirmController.text;
    if (newPassword.isEmpty) return;
    setState(() {
      _confirming = true;
      _confirmError = null;
    });
    try {
      // Only succeeds if `newPassword` really is the account's current
      // password right now — i.e. the reset button/page was actually
      // used to change it.
      await _authService.reauthenticate(newPassword);
      await AppLockService.resetAfterAccountVerification();
      final uid = _authService.currentUserId;
      if (uid != null) await DeviceSessionService.instance.logPasswordChanged(uid);
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _appLockCleared = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _confirmError = "That doesn't match your current password yet — make sure you've finished resetting it first.";
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
            Text(
              _identifierIsFixed
                  ? "We'll email a way to reset your password to ${widget.knownEmail}."
                  : "Enter your email or username and we'll email you a way to reset your password.",
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _identifierController,
              keyboardType: _identifierIsFixed ? TextInputType.text : TextInputType.emailAddress,
              enabled: !_emailSent && !_identifierIsFixed,
              decoration: InputDecoration(
                labelText: _identifierIsFixed ? 'Account email' : 'Email or username',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_emailError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_emailError!, style: TextStyle(color: scheme.error)),
              ),
            const SizedBox(height: 16),
            if (!_emailSent)
              FilledButton(
                onPressed: _sendingEmail ? null : _sendResetEmail,
                child: _sendingEmail
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send reset email'),
              )
            else if (_mode == 'otp')
              _buildOtpFlow(scheme)
            else
              _buildEmailFlow(scheme),
            if (_emailSent && _mode == 'email' && widget.alsoResetAppLock) _buildAppLockConfirm(scheme),
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

  Widget _buildEmailFlow(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.mark_email_read_outlined, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Check your inbox for a 'Reset your password' email — tap the button in it to set a new password. It may take a minute to arrive.",
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOtpFlow(ColorScheme scheme) {
    if (_otpResetDone) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: scheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _appLockCleared
                    ? 'Password updated and App lock turned off. You can sign in with your new password now.'
                    : 'Password updated. You can sign in with your new password now.',
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Enter the 6-digit code we sent to your email, then choose a new password.'),
        const SizedBox(height: 12),
        TextField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, letterSpacing: 8, fontWeight: FontWeight.bold),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(counterText: '', border: OutlineInputBorder()),
          onChanged: (v) {
            setState(() {
              _otpConfirmedFormat = v.trim().length == 6;
              _otpError = null;
            });
          },
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: (_resendCooldown > 0 || _sendingEmail) ? null : _resendOtp,
            child: Text(_resendCooldown > 0 ? 'Resend code in ${_resendCooldown}s' : 'Resend code'),
          ),
        ),
        if (_otpConfirmedFormat) ...[
          const SizedBox(height: 8),
          Text('New password', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          StrongPasswordFields(
            passwordController: _newPasswordController,
            confirmController: _confirmNewPasswordController,
            passwordLabel: 'New password',
            confirmLabel: 'Confirm new password',
            onChanged: () => setState(() {}),
          ),
        ],
        if (_otpError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_otpError!, style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: (_otpConfirmedFormat && !_resettingViaOtp) ? _submitOtpReset : null,
          child: _resettingViaOtp
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Reset password'),
        ),
      ],
    );
  }

  Widget _buildAppLockConfirm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        if (_appLockCleared)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
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
            "Once you've finished resetting it in the email, enter your new password below to also turn off App Lock.",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newPasswordConfirmController,
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
    );
  }
}
