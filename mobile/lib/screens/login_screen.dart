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
import 'settings/manage_devices_screen.dart';

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
    // BUGFIX: a second tap while a login (or its approval wait) is already
    // running must do nothing — two overlapping attempts were creating a
    // second approval request for the same sign-in.
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    // Feature: failed-login lockout — checked BEFORE anything else, so a
    // device/network that's already locked out from previous failures
    // never even reaches the Firebase sign-in call below.
    try {
      await _authService.checkLoginLockout();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
      return;
    }

    // BUGFIX: covers the ENTIRE login attempt, not just the approval wait
    // — see DeviceSessionService.isClaimPending's doc comment for the
    // full explanation. In short: this device hasn't claimed itself as
    // active yet at any point between here and finishLogin() actually
    // completing below, so watchForRemoteLogout (running independently in
    // main.dart the moment Firebase Auth signs in) needs to know not to
    // treat that as "someone else logged in" for this whole window.
    DeviceSessionService.instance.isClaimPending = true;
    // BUGFIX: tracks how far this attempt got, so that if ANYTHING fails after
    // the password was accepted (creating the approval request, waiting for it,
    // or finishing the sign-in) this phone is signed back out instead of being
    // left half signed-in. A half signed-in phone is what made a retry
    // impossible without clearing the app's data: it looked signed in, never
    // owned the account, and was kicked out again straight away.
    var passwordAccepted = false;
    var approved = false;
    var finished = false;
    String? uid;
    try {
      uid = await _authService.beginEmailLogin(_emailController.text.trim(), _passwordController.text);
      passwordAccepted = true;

      // BUGFIX: was DeviceSessionService.instance.isLoginApprovalRequired(uid)
      // — the raw toggle check, with no regard for whether the account's
      // other device is actually still around to answer. See
      // shouldRequireApprovalForNewLogin's doc comment for why that
      // permanently locked people out after an app delete/reinstall.
      if (await DeviceSessionService.instance.shouldRequireApprovalForNewLogin(uid)) {
        final handle = await DeviceSessionService.instance.createLoginApprovalRequest(uid);
        final requestId = handle.requestId;
        final outcome = await _waitForApproval(uid, requestId, handle.matchNumber);
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
        approved = true;
      }

      await _authService.finishLogin(uid);
      finished = true;
      await SettingsService.setStayLoggedIn(_stayLoggedIn);
      // AuthGate's authStateChanges listener takes it from here.
    } on DeviceLimitReachedException catch (e) {
      // Feature: multiple devices — the password already checked out and
      // this device is genuinely signed in to Firebase Auth at this point,
      // just not yet claimed as active. Let the person free up a slot
      // right here instead of failing the whole login.
      if (mounted) {
        final freed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => ManageDevicesScreen(uid: uid!, blockingLimit: e.limit)),
        );
        if (freed == true) {
          try {
            await _authService.finishLogin(uid!);
            finished = true;
            await SettingsService.setStayLoggedIn(_stayLoggedIn);
          } catch (_) {
            // Falls through to the abort/error handling below, same as any
            // other post-password failure.
          }
        }
      }
      if (!finished) {
        try {
          await _authService.abortLogin();
        } catch (_) {}
        if (mounted) setState(() => _error = "Couldn't finish signing in — try again.");
      }
    } catch (e) {
      debugPrint('Login failed (passwordAccepted=$passwordAccepted, approved=$approved): $e');
      // Feature: failed-login lockout — only counts as a "failure" for
      // lockout purposes if the PASSWORD itself was wrong (beginEmailLogin
      // threw before setting passwordAccepted); an approval being denied
      // or timing out, or finishLogin failing afterwards, are not
      // credential-guessing attempts and shouldn't count toward the block.
      if (!passwordAccepted) {
        unawaited(_authService.recordLoginFailure(_emailController.text.trim()));
      }
      if (passwordAccepted && !finished) {
        try {
          await _authService.abortLogin();
        } catch (_) {}
      }
      if (mounted) {
        setState(() => _error = approved
            ? 'Your other device approved this login, but signing in could not be finished. Please try again.'
            : _friendlyError(e));
      }
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
  Future<_ApprovalOutcome> _waitForApproval(String uid, String requestId, int matchNumber) async {
    final outcomeCompleter = Completer<_ApprovalOutcome>();

    final sub = DeviceSessionService.instance.watchApprovalStatus(uid, requestId).listen(
      (status) {
        if (outcomeCompleter.isCompleted) return;
        if (status == 'accepted') outcomeCompleter.complete(_ApprovalOutcome.accepted);
        if (status == 'denied') outcomeCompleter.complete(_ApprovalOutcome.denied);
      },
      // A failing status stream must not become an uncaught error — the wait
      // simply runs to its 60-second timeout instead.
      onError: (Object e) => debugPrint('watchApprovalStatus error: $e'),
    );
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
            children: [
              const Text(
                'Open NWisp on your other device and tap this number to approve the login:',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              // Feature: number matching — this is what the other device asks for.
              Text(
                '$matchNumber',
                style: Theme.of(dialogContext).textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                      color: Theme.of(dialogContext).colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 14),
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(height: 12),
              Text(
                'It times out after a minute.',
                style: TextStyle(color: Theme.of(dialogContext).colorScheme.onSurfaceVariant, fontSize: 12.5),
              ),
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
