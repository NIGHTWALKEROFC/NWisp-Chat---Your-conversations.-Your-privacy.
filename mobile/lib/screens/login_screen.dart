import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/branding_service.dart';
import '../services/device_session_service.dart';
import '../services/settings_service.dart';
import 'register_screen.dart';
import 'settings/forgot_password_screen.dart';
import 'settings/help_center_screen.dart';

enum _ApprovalOutcome { accepted, denied, timedOut, cancelled }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _stayLoggedIn = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    SettingsService.getStayLoggedIn().then((value) {
      if (mounted) setState(() => _stayLoggedIn = value);
    });
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // BUGFIX: covers the ENTIRE login attempt, not just the approval wait
    // — see DeviceSessionService.isClaimPending's doc comment for the
    // full explanation. In short: this device hasn't claimed itself as
    // active yet at any point between here and finishLogin() actually
    // completing below, so watchForRemoteLogout (running independently in
    // main.dart the moment Firebase Auth signs in) needs to know not to
    // treat that as "someone else logged in" for this whole window.
    DeviceSessionService.instance.isClaimPending = true;
    try {
      final uid = await _authService.beginEmailLogin(_emailController.text.trim(), _passwordController.text);

      if (await DeviceSessionService.instance.isLoginApprovalRequired(uid)) {
        final requestId = await DeviceSessionService.instance.createLoginApprovalRequest(uid);
        final outcome = await _waitForApproval(uid, requestId);
        if (outcome != _ApprovalOutcome.accepted) {
          await DeviceSessionService.instance.expireLoginApprovalRequest(uid, requestId);
          await _authService.abortLogin();
          if (mounted) {
            setState(() => _error = switch (outcome) {
              _ApprovalOutcome.denied => 'The login was denied from your other device.',
              _ApprovalOutcome.timedOut => "Nobody responded in time. Try again, or check your other device.",
              _ApprovalOutcome.cancelled => null,
              _ApprovalOutcome.accepted => null,
            });
          }
          return;
        }
      }

      await _authService.finishLogin(uid);
      await SettingsService.setStayLoggedIn(_stayLoggedIn);
      // AuthGate's authStateChanges listener takes it from here.
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyError(e));
    } finally {
      DeviceSessionService.instance.isClaimPending = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Shows a non-dismissible "waiting for approval" dialog and resolves
  /// once the other device responds, the 60-second window elapses, or the
  /// person taps Cancel — whichever happens first. Only ever one of these
  /// three ends the wait; the losers are cleaned up (stream cancelled,
  /// timer cancelled, dialog popped) before returning.
  Future<_ApprovalOutcome> _waitForApproval(String uid, String requestId) async {
    final outcomeCompleter = Completer<_ApprovalOutcome>();

    final sub = DeviceSessionService.instance.watchApprovalStatus(uid, requestId).listen((status) {
      if (outcomeCompleter.isCompleted) return;
      if (status == 'accepted') outcomeCompleter.complete(_ApprovalOutcome.accepted);
      if (status == 'denied') outcomeCompleter.complete(_ApprovalOutcome.denied);
    });
    final timeoutTimer = Timer(const Duration(seconds: 60), () {
      if (!outcomeCompleter.isCompleted) outcomeCompleter.complete(_ApprovalOutcome.timedOut);
    });

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Waiting for approval'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Approve this login from your other device, or wait for it to time out.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!outcomeCompleter.isCompleted) outcomeCompleter.complete(_ApprovalOutcome.cancelled);
                Navigator.pop(dialogContext);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }

    final outcome = await outcomeCompleter.future;
    await sub.cancel();
    timeoutTimer.cancel();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    return outcome;
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('invalid-credential') || msg.contains('wrong-password')) {
      return 'Incorrect email or password.';
    }
    if (msg.contains('user-not-found')) return 'No account found for that email.';
    if (msg.contains('too-many-requests')) return 'Too many attempts. Try again later.';
    return 'Sign-in failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help Centre',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
            ),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Icon(Icons.lock_outline_rounded, size: 56, color: scheme.primary),
                const SizedBox(height: 12),
                Text(
                  'Welcome back',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Sign in to continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                    ),
                    child: const Text('Forgot password?'),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Stay signed in'),
                  subtitle: const Text('Off = sign in again every time you open the app'),
                  value: _stayLoggedIn,
                  onChanged: (v) => setState(() => _stayLoggedIn = v),
                ),
                const SizedBox(height: 8),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                ElevatedButton(
                  onPressed: _loading ? null : _login,
                  child: _loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                        )
                      : const Text('Sign in'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                  ),
                  child: const Text("Don't have an account? Sign up"),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
