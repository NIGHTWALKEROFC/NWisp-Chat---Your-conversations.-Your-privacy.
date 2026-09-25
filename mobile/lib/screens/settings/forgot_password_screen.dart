import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';
import '../../widgets/breach_warning_dialog.dart';
import '../../widgets/contact_developer_sheet.dart';
import '../../widgets/otp_code_field.dart';
import '../../widgets/strong_password_fields.dart';
import '../../widgets/turnstile_captcha.dart';

enum _Step { chooseMethod, identifier, code, newPassword, done }

enum _Method { code, link }

/// The "Reset password" screen. It ALWAYS starts by asking how you want to
/// reset — nothing is decided for you, and nothing is pre-selected:
///
///   * Reset with a code        -> a 6-digit code is emailed; you type it into
///                                 Telegram-style boxes (they turn GREEN when
///                                 the code is right and RED when it's wrong),
///                                 then choose a new password, all without
///                                 leaving the app.
///   * Reset with an email link -> a "Reset your password" button is emailed
///                                 (the original flow).
///
/// What the SERVER reports it actually did (`mode` in its reply) is treated as
/// the truth: if the person asked for a code but the server could only send a
/// link (or the other way round), the screen follows what really happened
/// instead of leaving them waiting for the wrong thing.
class ForgotPasswordScreen extends StatefulWidget {
  final bool alsoResetAppLock;

  /// Set when this screen is opened from WITHIN an already-signed-in
  /// account (Account Security -> "Not sure this was you?") — we already
  /// know this account's email in that case, so there's no reason to make
  /// the person type it again. When null (the normal pre-login "Forgot
  /// password?" entry point), the person types either their email OR their
  /// username.
  final String? knownEmail;

  const ForgotPasswordScreen({super.key, this.alsoResetAppLock = false, this.knownEmail});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _authService = AuthService();

  _Step _step = _Step.chooseMethod;
  _Method? _method; // null until the person picks — there is no default

  // ---- identifier step (shared) ----
  late final _identifierController = TextEditingController(text: widget.knownEmail ?? '');
  bool get _identifierIsFixed => widget.knownEmail != null;
  String _identifier = '';
  bool _sending = false;
  String? _identifierError;
  String? _notice; // e.g. "we emailed a link instead"

  // ---- "email link" method ----
  bool _linkSent = false;

  // BUGFIX (security): this screen used to turn off App Lock the instant
  // the reset EMAIL was sent — not once the password was actually changed.
  // Since sending a reset email only requires knowing the account's email
  // address (which isn't secret), anyone with a few seconds of access to
  // an unlocked phone but a locked app could tap "Forgot PIN?" -> "I've
  // also forgotten my account password" -> type the owner's email ->
  // App Lock disabled immediately, without ever touching the owner's
  // inbox or actually resetting anything. That defeated the entire point
  // of App Lock. Now, for the "also reset app lock" flow:
  //   - link: App Lock only clears after the person enters the NEW
  //     password here and we verify it against Firebase directly
  //     (reauthenticate) — proving the reset link was actually used.
  //   - code: the new password is set server-side only after the emailed
  //     code checks out, so there's nothing left to "prove" — App Lock
  //     clears right after that succeeds.
  final _appLockPasswordController = TextEditingController();
  bool _confirming = false;
  String? _confirmError;
  bool _appLockCleared = false;

  // ---- "code" method ----
  final _otpKey = GlobalKey<OtpCodeFieldState>();
  OtpFieldStatus _otpStatus = OtpFieldStatus.idle;
  String? _otpMessage;
  bool _verifying = false;
  String? _verifiedCode;
  int _resendCooldown = 0;
  Timer? _resendTimer;

  // ---- choosing the new password (code method) ----
  final _newPasswordController = TextEditingController();
  final _confirmNewPasswordController = TextEditingController();
  bool _saving = false;
  String? _passwordError;

  static const int _minPasswordLength = 6;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _identifierController.dispose();
    _appLockPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmNewPasswordController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Moving between steps
  // ------------------------------------------------------------------

  void _chooseMethod(_Method method) {
    setState(() {
      _method = method;
      _step = _Step.identifier;
      _identifierError = null;
      _notice = null;
      _linkSent = false;
    });
  }

  void _goBack() {
    switch (_step) {
      case _Step.chooseMethod:
      case _Step.done:
        Navigator.pop(context);
        break;
      case _Step.identifier:
        setState(() {
          _step = _Step.chooseMethod;
          _method = null;
          _identifierError = null;
          _notice = null;
          _linkSent = false;
        });
        break;
      case _Step.code:
        _resendTimer?.cancel();
        setState(() => _step = _Step.identifier);
        break;
      case _Step.newPassword:
        setState(() {
          _step = _Step.code;
          _otpStatus = OtpFieldStatus.idle;
          _otpMessage = null;
          _passwordError = null;
        });
        break;
    }
  }

  // ------------------------------------------------------------------
  // Step: who are you, then send the code or the link
  // ------------------------------------------------------------------

  Future<void> _continueWithIdentifier() async {
    if (_sending) return;
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty) {
      setState(() => _identifierError = 'Enter your email or username.');
      return;
    }
    setState(() {
      _sending = true;
      _identifierError = null;
      _notice = null;
    });
    final turnstileToken = await TurnstileCaptcha.requestToken(context);
    if (turnstileToken == null) {
      if (!mounted) return;
      setState(() => _sending = false);
      return;
    }
    try {
      final result = await _authService.requestPasswordReset(
        identifier,
        method: _method == _Method.code ? 'otp' : 'email',
        turnstileToken: turnstileToken,
      );
      if (!mounted) return;
      _identifier = identifier;
      final mode = (result['mode'] as String?) ?? 'email';
      setState(() => _sending = false);

      if (mode == 'otp') {
        // Whatever was asked for, a code is what was sent — so go to the code step.
        setState(() {
          _step = _Step.code;
          _otpStatus = OtpFieldStatus.idle;
          _otpMessage = null;
          _verifiedCode = null;
          _notice = _method == _Method.link ? "We sent a code instead of a link — enter it below." : null;
        });
        _startResendCooldown();
      } else {
        setState(() {
          _linkSent = true;
          _notice = _method == _Method.code
              ? "We couldn't send a code, so we emailed you a reset link instead."
              : null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _identifierError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ------------------------------------------------------------------
  // Step: enter the code
  // ------------------------------------------------------------------

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

  Future<void> _resendCode() async {
    if (_resendCooldown > 0 || _sending) return;
    setState(() {
      _sending = true;
      _otpMessage = null;
    });
    final turnstileToken = await TurnstileCaptcha.requestToken(context);
    if (turnstileToken == null) {
      if (!mounted) return;
      setState(() => _sending = false);
      return;
    }
    try {
      await _authService.requestPasswordReset(_identifier, method: 'otp', turnstileToken: turnstileToken);
      if (!mounted) return;
      setState(() => _sending = false);
      _otpKey.currentState?.clear();
      _otpKey.currentState?.focus();
      _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _otpStatus = OtpFieldStatus.idle;
        _otpMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _onCodeEntered(String code) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _otpMessage = null;
    });
    try {
      await _authService.checkPasswordResetOtp(email: _identifier, code: code);
      if (!mounted) return;
      _verifiedCode = code;
      // Every box fills green...
      setState(() {
        _verifying = false;
        _otpStatus = OtpFieldStatus.success;
        _otpMessage = 'Code verified';
      });
      // ...and after a beat, on to choosing the new password.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      setState(() {
        _step = _Step.newPassword;
        _passwordError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Every box fills red and shakes...
      setState(() {
        _verifying = false;
        _otpStatus = OtpFieldStatus.error;
        _otpMessage = e.toString().replaceFirst('Exception: ', '');
      });
      // ...then clears itself so they can try again.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      if (!mounted) return;
      _otpKey.currentState?.clear();
      setState(() => _otpStatus = OtpFieldStatus.idle);
      _otpKey.currentState?.focus();
    }
  }

  // ------------------------------------------------------------------
  // Step: choose the new password (code method)
  // ------------------------------------------------------------------

  Future<void> _saveNewPassword() async {
    if (_saving) return;
    final password = _newPasswordController.text;
    if (password.length < _minPasswordLength) {
      setState(() => _passwordError = 'Password must be at least $_minPasswordLength characters.');
      return;
    }
    if (password != _confirmNewPasswordController.text) {
      setState(() => _passwordError = "Passwords don't match.");
      return;
    }
    final code = _verifiedCode;
    if (code == null) {
      setState(() => _step = _Step.code);
      return;
    }
    // Warns (and lets them choose) if this password appears in known leaks.
    final ok = await confirmPasswordNotBreached(context, password);
    if (!ok || !mounted) return;

    setState(() {
      _saving = true;
      _passwordError = null;
    });
    try {
      await _authService.verifyPasswordResetOtp(email: _identifier, code: code, newPassword: password);
      if (!mounted) return;
      _resendTimer?.cancel();

      // The new password was set server-side only after the emailed code
      // checked out, so — unlike the link flow — there's nothing left to
      // prove before clearing App Lock.
      var cleared = false;
      if (widget.alsoResetAppLock) {
        try {
          final uid = _authService.currentUserId;
          await AppLockService.resetAfterAccountVerification();
          if (uid != null) await DeviceSessionService.instance.logPasswordChanged(uid);
          cleared = true;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _appLockCleared = cleared;
        _step = _Step.done;
      });
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '');
      // If the problem is the code itself (expired, too many tries), go back
      // to the code step rather than leaving them stuck on this one.
      if (message.toLowerCase().contains('code')) {
        setState(() {
          _saving = false;
          _step = _Step.code;
          _otpStatus = OtpFieldStatus.idle;
          _otpMessage = message;
        });
      } else {
        setState(() {
          _saving = false;
          _passwordError = message;
        });
      }
    }
  }

  // ------------------------------------------------------------------
  // "email link" method: the App Lock confirmation
  // ------------------------------------------------------------------

  Future<void> _confirmNewPasswordAndClearAppLock() async {
    final newPassword = _appLockPasswordController.text;
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

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  Widget _methodCard({
    required ColorScheme scheme,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoBox(ColorScheme scheme, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: scheme.onPrimaryContainer))),
        ],
      ),
    );
  }

  Widget _buildChooseMethod(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('How do you want to reset your password?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text('Pick one — you can always come back and choose the other.', style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 20),
        _methodCard(
          scheme: scheme,
          icon: Icons.pin_outlined,
          title: 'Reset with a code',
          subtitle: 'We email you a 6-digit code. Enter it here and choose a new password without leaving the app.',
          onTap: () => _chooseMethod(_Method.code),
        ),
        _methodCard(
          scheme: scheme,
          icon: Icons.link,
          title: 'Reset with an email link',
          subtitle: 'We email you a button. Tap it to set a new password in your browser.',
          onTap: () => _chooseMethod(_Method.link),
        ),
      ],
    );
  }

  Widget _buildIdentifierStep(ColorScheme scheme) {
    final isCode = _method == _Method.code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _identifierIsFixed
              ? "We'll email ${isCode ? 'a 6-digit code' : 'a reset link'} to ${widget.knownEmail}."
              : "Enter your email or username and we'll email you ${isCode ? 'a 6-digit code' : 'a reset link'}.",
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _identifierController,
          keyboardType: _identifierIsFixed ? TextInputType.text : TextInputType.emailAddress,
          enabled: !_linkSent && !_identifierIsFixed,
          autofocus: !_identifierIsFixed,
          onSubmitted: (_) => _continueWithIdentifier(),
          decoration: InputDecoration(
            labelText: _identifierIsFixed ? 'Account email' : 'Email or username',
            border: const OutlineInputBorder(),
          ),
        ),
        if (_identifierError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_identifierError!, style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 16),
        if (_linkSent) ...[
          if (_notice != null) ...[
            Text(_notice!, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
          ],
          _infoBox(
            scheme,
            Icons.mark_email_read_outlined,
            "Check your inbox for a 'Reset your password' email — tap the button in it to set a new password. It may take a minute to arrive.",
          ),
          if (widget.alsoResetAppLock) _buildAppLockConfirm(scheme),
        ] else
          FilledButton(
            onPressed: _sending ? null : _continueWithIdentifier,
            child: _sending
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(isCode ? 'Send code' : 'Send reset email'),
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
          _infoBox(scheme, Icons.lock_open_outlined, 'App lock turned off. Set a new PIN anytime in Settings.')
        else ...[
          Text(
            "Once you've finished resetting it in the email, enter your new password below to also turn off App Lock.",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _appLockPasswordController,
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

  Widget _buildCodeStep(ColorScheme scheme) {
    final message = _otpMessage;
    final Color messageColor = _otpStatus == OtpFieldStatus.success
        ? const Color(0xFF2E9E5B)
        : (_otpStatus == OtpFieldStatus.error ? scheme.error : scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Enter the code', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'We emailed a 6-digit code to the account for "$_identifier". It can take a minute — check spam too. It expires in 10 minutes.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 8),
          Text(_notice!, style: TextStyle(color: scheme.primary)),
        ],
        const SizedBox(height: 28),
        Center(
          child: OtpCodeField(
            key: _otpKey,
            status: _otpStatus,
            enabled: !_verifying,
            onChanged: (_) {
              if (_otpMessage != null && _otpStatus == OtpFieldStatus.idle) setState(() => _otpMessage = null);
            },
            onCompleted: _onCodeEntered,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 22,
          child: _verifying
              ? const Center(child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : (message != null
                  ? Text(message, textAlign: TextAlign.center, style: TextStyle(color: messageColor, fontWeight: FontWeight.w600))
                  : null),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: (_resendCooldown > 0 || _sending || _verifying) ? null : _resendCode,
          child: Text(_resendCooldown > 0 ? 'Resend code in ${_resendCooldown}s' : 'Resend code'),
        ),
      ],
    );
  }

  Widget _buildNewPasswordStep(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Choose a new password', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('At least $_minPasswordLength characters.', style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 20),
        StrongPasswordFields(
          passwordController: _newPasswordController,
          confirmController: _confirmNewPasswordController,
          passwordLabel: 'New password',
          confirmLabel: 'Confirm new password',
          onChanged: () => setState(() => _passwordError = null),
        ),
        if (_passwordError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_passwordError!, style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : _saveNewPassword,
          child: _saving
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Change password'),
        ),
      ],
    );
  }

  Widget _buildDone(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.check_circle, size: 64, color: Color(0xFF2E9E5B)),
        const SizedBox(height: 16),
        Text('Password changed', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          _appLockCleared
              ? 'App lock has been turned off. You can set a new PIN anytime in Settings, and sign in with your new password.'
              : 'You can now sign in with your new password.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget body;
    switch (_step) {
      case _Step.chooseMethod:
        body = _buildChooseMethod(scheme);
        break;
      case _Step.identifier:
        body = _buildIdentifierStep(scheme);
        break;
      case _Step.code:
        body = _buildCodeStep(scheme);
        break;
      case _Step.newPassword:
        body = _buildNewPasswordStep(scheme);
        break;
      case _Step.done:
        body = _buildDone(scheme);
        break;
    }
    return PopScope(
      // The system back button steps back through the flow instead of
      // leaving the screen mid-way.
      canPop: _step == _Step.chooseMethod || _step == _Step.done,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reset password'),
          leading: BackButton(onPressed: _goBack),
        ),
        body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: body),
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
      ),
    );
  }
}
