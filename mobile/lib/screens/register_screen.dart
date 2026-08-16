import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
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

enum _UsernameCheck { idle, checking, available, taken, invalid }

enum _EmailCheck { idle, checking, looksNew, looksTaken, invalid }

class _RegisterScreenState extends State<RegisterScreen> {
  final _authService = AuthService();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  int _step = 0;
  static const _totalSteps = 4;

  _UsernameCheck _usernameCheck = _UsernameCheck.idle;
  Timer? _usernameDebounce;
  int _usernameRequestId = 0;

  _EmailCheck _emailCheck = _EmailCheck.idle;
  Timer? _emailDebounce;
  int _emailRequestId = 0;

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _agreedPrivacy = false;
  bool _agreedTerms = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _emailDebounce?.cancel();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  // ---------- Step 1: username ----------

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
      case _UsernameCheck.invalid:
        return Text(
          'At least 3 characters — lowercase letters, numbers, and underscores only',
          style: TextStyle(color: scheme.error, fontSize: 12.5),
        );
    }
  }

  bool get _canProceedFromUsername => _usernameCheck == _UsernameCheck.available;

  // ---------- Step 2: email ----------

  void _onEmailChanged(String value) {
    _emailDebounce?.cancel();
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

  // ---------- Step 3: password ----------

  bool get _canProceedFromPassword {
    final pw = _passwordController.text;
    return pw.length >= 6 && pw == _confirmController.text;
  }

  // ---------- navigation ----------

  void _next() {
    setState(() => _error = null);
    if (_step == 0 && !_canProceedFromUsername) {
      setState(() => _error = 'Pick an available username to continue.');
      return;
    }
    if (_step == 1 && !_canProceedFromEmail) {
      setState(() => _error = 'Enter an email that looks available.');
      return;
    }
    if (_step == 2 && !_canProceedFromPassword) {
      setState(() => _error = _passwordController.text.length < 6
          ? 'Password must be at least 6 characters.'
          : "Passwords don't match.");
      return;
    }
    if (_step < _totalSteps - 1) setState(() => _step++);
  }

  void _back() {
    setState(() => _error = null);
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
        leading: _step > 0
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _loading ? null : _back)
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
                      onPressed: _loading ? null : (_step == _totalSteps - 1 ? _createAccount : _next),
                      child: _loading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Text(_step == _totalSteps - 1 ? 'Create account' : 'Continue'),
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
      case 0:
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
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add your email', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              "We'll send a verification link here once your account is created.",
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
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Set a password', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('At least 6 characters.', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            TextField(
              controller: _passwordController,
              autofocus: true,
              obscureText: _obscurePassword,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmController,
              obscureText: _obscureConfirm,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Confirm password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
            ),
            if (_confirmController.text.isNotEmpty && _confirmController.text != _passwordController.text)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text("Passwords don't match", style: TextStyle(color: scheme.error, fontSize: 12.5)),
              ),
          ],
        );
      case 3:
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Review & agree', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            _ReviewRow(label: 'Username', value: _usernameController.text.trim()),
            _ReviewRow(label: 'Email', value: _emailController.text.trim()),
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
