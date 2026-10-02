import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../widgets/breach_warning_dialog.dart';
import '../widgets/otp_code_field.dart';
import '../widgets/strong_password_fields.dart';
import '../widgets/turnstile_captcha.dart';
import 'settings/privacy_policy_screen.dart';
import 'settings/terms_screen.dart';

/// Forces lowercase as the user types, the way Instagram's username field
/// does — this is enforced going forward for new signups only; existing
/// accounts created with mixed-case usernames are left exactly as they are.
class _LowerCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toLowerCase());
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

enum _UsernameCheck { idle, checking, available, taken, invalid, botName }

enum _EmailCheck { idle, checking, looksNew, looksTaken, invalid }

// Feature: Instagram-style signup — steps are now username -> email ->
// verify (6-digit code emailed to that address) -> password -> review.
// The old flow sent a "click to confirm" link only AFTER the account and
// password already existed; this confirms the email FIRST, the way
// Instagram/most modern apps do, and there's no separate link-click step
// at all anymore — entering the code IS the confirmation.
const _stepUsername = 0;
const _stepEmail = 1;
const _stepVerify = 2;
const _stepPassword = 3;
const _stepReview = 4;

class _RegisterScreenState extends State<RegisterScreen> {
  final _authService = AuthService();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  int _step = _stepUsername;
  static const _totalSteps = 5;

  _UsernameCheck _usernameCheck = _UsernameCheck.idle;
  Timer? _usernameDebounce;
  int _usernameRequestId = 0;

  _EmailCheck _emailCheck = _EmailCheck.idle;
  Timer? _emailDebounce;
  int _emailRequestId = 0;

  // ---- email verification (OTP) state ----
  // Feature: Telegram-style boxed code entry (same widget the password
  // reset screen already uses) instead of a plain text field.
  final _otpKey = GlobalKey<OtpCodeFieldState>();
  String _otpCode = '';
  OtpFieldStatus _otpStatus = OtpFieldStatus.idle;
  bool _emailVerified = false;
  bool _sendingOtp = false;
  bool _verifyingOtp = false;
  String? _otpError;
  int _resendCooldown = 0;
  Timer? _resendTimer;

  bool _agreedPrivacy = false;
  bool _agreedTerms = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _emailDebounce?.cancel();
    _resendTimer?.cancel();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  // ---------- Step: username ----------

  void _onUsernameChanged(String value) {
    _usernameDebounce?.cancel();
    // The input field itself already forces lowercase as you type (see
    // _LowerCaseTextFormatter) — this trim/lowercase is just a safety net.
    final trimmed = value.trim().toLowerCase();
    if (trimmed.length < 3) {
      setState(() => _usernameCheck = trimmed.isEmpty ? _UsernameCheck.idle : _UsernameCheck.invalid);
      return;
    }
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(trimmed)) {
      setState(() => _usernameCheck = _UsernameCheck.invalid);
      return;
    }
    // Feature: NWisp Bots — names ending in a single _bot are reserved for bots.
    if (AuthService.isBotStyleUsername(trimmed)) {
      setState(() => _usernameCheck = _UsernameCheck.botName);
      return;
    }
    setState(() => _usernameCheck = _UsernameCheck.checking);
    final myRequestId = ++_usernameRequestId;
    _usernameDebounce = Timer(const Duration(milliseconds: 450), () async {
      final available = await _authService.isUsernameAvailable(trimmed);
      if (!mounted || myRequestId != _usernameRequestId) return;
      setState(() => _usernameCheck = available ? _UsernameCheck.available : _UsernameCheck.taken);
    });
  }

  Widget? _usernameStatusWidget(ColorScheme scheme) {
    switch (_usernameCheck) {
      case _UsernameCheck.idle:
        return null;
      case _UsernameCheck.checking:
        return Row(mainAxisSize: MainAxisSize.min, children: const [
          SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Checking availability…'),
        ]);
      case _UsernameCheck.available:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
          const SizedBox(width: 6),
          Text('Username available', style: TextStyle(color: Colors.green.shade600)),
        ]);
      case _UsernameCheck.taken:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cancel, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Text('Already taken', style: TextStyle(color: scheme.error)),
        ]);
      case _UsernameCheck.botName:
        return Text(
          AuthService.botNameMessage,
          style: TextStyle(color: scheme.error, fontSize: 12.5),
        );
      case _UsernameCheck.invalid:
        return Text(
          'At least 3 characters — lowercase letters, numbers, and underscores only',
          style: TextStyle(color: scheme.error, fontSize: 12.5),
        );
    }
  }

  bool get _canProceedFromUsername => _usernameCheck == _UsernameCheck.available;

  // ---------- Step: email ----------

  void _onEmailChanged(String value) {
    _emailDebounce?.cancel();
    // Changing the email after it was verified invalidates that
    // verification — they'd otherwise be able to "verify" one address
    // and submit a different one.
    if (_emailVerified) setState(() => _emailVerified = false);
    final trimmed = value.trim();
    final validFormat = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed);
    if (!validFormat) {
      setState(() => _emailCheck = trimmed.isEmpty ? _EmailCheck.idle : _EmailCheck.invalid);
      return;
    }
    setState(() => _emailCheck = _EmailCheck.checking);
    final myRequestId = ++_emailRequestId;
    _emailDebounce = Timer(const Duration(milliseconds: 450), () async {
      final likelyAvailable = await _authService.isEmailLikelyAvailable(trimmed);
      if (!mounted || myRequestId != _emailRequestId) return;
      setState(() => _emailCheck = likelyAvailable ? _EmailCheck.looksNew : _EmailCheck.looksTaken);
    });
  }

  Widget? _emailStatusWidget(ColorScheme scheme) {
    switch (_emailCheck) {
      case _EmailCheck.idle:
        return null;
      case _EmailCheck.checking:
        return Row(mainAxisSize: MainAxisSize.min, children: const [
          SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Checking…'),
        ]);
      case _EmailCheck.looksNew:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
          const SizedBox(width: 6),
          Text('Looks good', style: TextStyle(color: Colors.green.shade600)),
        ]);
      case _EmailCheck.looksTaken:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cancel, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Text('Already registered', style: TextStyle(color: scheme.error)),
        ]);
      case _EmailCheck.invalid:
        return Text('Enter a valid email address', style: TextStyle(color: scheme.error, fontSize: 12.5));
    }
  }

  bool get _canProceedFromEmail => _emailCheck == _EmailCheck.looksNew || _emailCheck == _EmailCheck.checking;

  // ---------- Step: verify email (OTP) ----------

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

  Future<void> _sendOtpAndAdvance() async {
    setState(() {
      _sendingOtp = true;
      _error = null;
      _otpError = null;
    });
    // CAPTCHA first — solved token is required by send-signup-otp.
    final turnstileToken = await TurnstileCaptcha.requestToken(context);
    if (turnstileToken == null) {
      if (!mounted) return;
      setState(() => _sendingOtp = false);
      return;
    }
    try {
      await _authService.sendSignupOtp(_emailController.text.trim(), turnstileToken: turnstileToken);
      if (!mounted) return;
      _otpCode = '';
      _otpStatus = OtpFieldStatus.idle;
      _otpKey.currentState?.clear();
      setState(() {
        _sendingOtp = false;
        _step = _stepVerify;
      });
      _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingOtp = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _resendOtp() async {
    if (_resendCooldown > 0) return;
    setState(() {
      _sendingOtp = true;
      _otpError = null;
    });
    final turnstileToken = await TurnstileCaptcha.requestToken(context);
    if (turnstileToken == null) {
      if (!mounted) return;
      setState(() => _sendingOtp = false);
      return;
    }
    try {
      await _authService.sendSignupOtp(_emailController.text.trim(), turnstileToken: turnstileToken);
      if (!mounted) return;
      _otpCode = '';
      _otpStatus = OtpFieldStatus.idle;
      _otpKey.currentState?.clear();
      _otpKey.currentState?.focus();
      setState(() => _sendingOtp = false);
      _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingOtp = false;
        _otpError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _verifyOtpAndAdvance() async {
    if (_verifyingOtp) return; // guards against onCompleted + the bottom button both firing
    final code = _otpCode;
    if (code.length != 6) {
      setState(() => _otpError = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _verifyingOtp = true;
      _otpError = null;
    });
    try {
      await _authService.verifySignupOtp(_emailController.text.trim(), code);
      if (!mounted) return;
      _resendTimer?.cancel();
      setState(() {
        _verifyingOtp = false;
        _otpStatus = OtpFieldStatus.success;
        _emailVerified = true;
      });
      // A short beat so the person actually sees the boxes turn green
      // (matching the password-reset screen's own timing) before moving
      // on to the next step.
      await Future.delayed(const Duration(milliseconds: 450));
      if (!mounted) return;
      setState(() => _step = _stepPassword);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifyingOtp = false;
        _otpStatus = OtpFieldStatus.error;
        _otpError = e.toString().replaceFirst('Exception: ', '');
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      _otpCode = '';
      _otpKey.currentState?.clear();
      setState(() => _otpStatus = OtpFieldStatus.idle);
      _otpKey.currentState?.focus();
    }
  }

  // ---------- Step: password ----------

  bool get _canProceedFromPassword {
    final pw = _passwordController.text;
    return pw.length >= 6 && pw == _confirmController.text;
  }

  // ---------- navigation ----------

  void _next() async {
    setState(() => _error = null);
    if (_step == _stepUsername && !_canProceedFromUsername) {
      setState(() => _error = 'Pick an available username to continue.');
      return;
    }
    if (_step == _stepEmail) {
      if (!_canProceedFromEmail) {
        setState(() => _error = 'Enter an email that looks available.');
        return;
      }
      _sendOtpAndAdvance();
      return;
    }
    if (_step == _stepVerify) {
      // Already confirmed (e.g. they went back to peek at this step and
      // are just moving forward again) — no need to re-spend the
      // already-consumed one-time code against the server.
      if (_emailVerified) {
        setState(() => _step = _stepPassword);
        return;
      }
      _verifyOtpAndAdvance();
      return;
    }
    if (_step == _stepPassword) {
      if (!_canProceedFromPassword) {
        setState(() => _error = _passwordController.text.length < 6
            ? 'Password must be at least 6 characters.'
            : "Passwords don't match.");
        return;
      }
      // Feature: breached-password warning — checked here, right as
      // they try to leave this step, rather than on every keystroke.
      final ok = await confirmPasswordNotBreached(context, _passwordController.text);
      if (!ok || !mounted) return;
    }
    if (_step < _totalSteps - 1) setState(() => _step++);
  }

  void _back() {
    setState(() => _error = null);
    if (_step == _stepVerify) _resendTimer?.cancel();
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _createAccount() async {
    if (!_agreedPrivacy || !_agreedTerms) {
      setState(() => _error = 'Please agree to both the Privacy Policy and Terms of Service to continue.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _authService.registerWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        username: _usernameController.text.trim().toLowerCase(),
      );
      // On success, AuthGate's authStateChanges listener takes over and
      // navigates to the home screen automatically.
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('email-already-in-use')) return 'That email is already registered.';
    if (msg.contains('weak-password')) return 'Password is too weak (min 6 characters).';
    if (msg.contains('Username already taken')) return 'That username is taken — try another.';
    if (msg.contains('invalid-email')) return 'That email address looks invalid.';
    return 'Sign-up failed. Please try again.';
  }

  bool get _loadingAnyStep => _loading || _sendingOtp || _verifyingOtp;

  String get _primaryLabel {
    switch (_step) {
      case _stepEmail:
        return 'Send code';
      case _stepVerify:
        return 'Verify';
      case _stepReview:
        return 'Create account';
      default:
        return 'Continue';
    }
  }

  VoidCallback? get _primaryAction {
    if (_loadingAnyStep) return null;
    return _step == _stepReview ? _createAccount : _next;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
        leading: _step > 0
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _loadingAnyStep ? null : _back)
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: (_step + 1) / _totalSteps),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildStep(scheme),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!, style: TextStyle(color: scheme.error)),
                      ),
                    ElevatedButton(
                      onPressed: _primaryAction,
                      child: _loadingAnyStep
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Text(_primaryLabel),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(ColorScheme scheme) {
    switch (_step) {
      case _stepUsername:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose a username', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('This is how people find and message you. Lowercase only.', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            TextField(
              controller: _usernameController,
              autofocus: true,
              inputFormatters: [_LowerCaseTextFormatter()],
              onChanged: _onUsernameChanged,
              decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
            ),
            const SizedBox(height: 8),
            if (_usernameStatusWidget(scheme) != null) _usernameStatusWidget(scheme)!,
          ],
        );
      case _stepEmail:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add your email', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              "We'll send a 6-digit code here to confirm it's yours.",
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _emailController,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              onChanged: _onEmailChanged,
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
            ),
            const SizedBox(height: 8),
            if (_emailStatusWidget(scheme) != null) _emailStatusWidget(scheme)!,
          ],
        );
      case _stepVerify:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Check your email', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Enter the 6-digit code we sent to ${_emailController.text.trim()}.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            OtpCodeField(
              key: _otpKey,
              status: _otpStatus,
              enabled: !_verifyingOtp,
              onChanged: (value) => _otpCode = value,
              onCompleted: (_) => _verifyOtpAndAdvance(),
            ),
            if (_otpError != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_otpError!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error, fontSize: 12.5)),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: (_resendCooldown > 0 || _sendingOtp) ? null : _resendOtp,
                child: Text(_resendCooldown > 0 ? 'Resend code in ${_resendCooldown}s' : 'Resend code'),
              ),
            ),
          ],
        );
      case _stepPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Set a password', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('At least 6 characters.', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            StrongPasswordFields(
              passwordController: _passwordController,
              confirmController: _confirmController,
              onChanged: () => setState(() {}),
            ),
          ],
        );
      case _stepReview:
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Review & agree', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            _ReviewRow(label: 'Username', value: _usernameController.text.trim()),
            _ReviewRow(label: 'Email', value: _emailController.text.trim()),
            Row(
              children: [
                Icon(Icons.verified, size: 15, color: Colors.green.shade600),
                const SizedBox(width: 6),
                Text('Email verified', style: TextStyle(color: Colors.green.shade600, fontSize: 12.5)),
              ],
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _agreedPrivacy,
              onChanged: (v) => setState(() => _agreedPrivacy = v ?? false),
              title: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('I agree to the '),
                  GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen())),
                    child: Text('Privacy Policy', style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline)),
                  ),
                ],
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _agreedTerms,
              onChanged: (v) => setState(() => _agreedTerms = v ?? false),
              title: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('I agree to the '),
                  GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen())),
                    child: Text('Terms & Conditions', style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline)),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;
  const _ReviewRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
