import 'package:flutter/material.dart';
import '../services/app_lock_service.dart';
import '../services/auth_service.dart';
import '../services/presence_service.dart';
import '../services/settings_service.dart';
import 'chat_list_screen.dart';
import 'login_screen.dart';

/// Decides what the user sees on launch:
/// - "Stay signed in" is OFF -> always sign out and show Login.
/// - "Stay signed in" is ON (default) -> follow Firebase's own session
///   state, so a signed-in user goes straight to their chats instead of
///   being asked to log in again every time the app is reopened.
/// - If App Lock is on, a PIN screen sits in front of the chats even when
///   the Firebase session is still valid.
///
/// Also starts/stops best-effort presence (see PresenceService) as the app
/// moves to and from the foreground.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  final _authService = AuthService();
  late final Future<bool> _stayLoggedIn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stayLoggedIn = _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PresenceService.goOffline();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authService.currentUser == null) return;
    if (state == AppLifecycleState.resumed) {
      PresenceService.goOnline();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      PresenceService.goOffline();
    }
  }

  Future<bool> _prepare() async {
    final stayLoggedIn = await SettingsService.getStayLoggedIn();
    if (!stayLoggedIn) {
      await _authService.logout();
    }
    return stayLoggedIn;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _stayLoggedIn,
      builder: (context, prefSnapshot) {
        if (!prefSnapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return StreamBuilder(
          stream: _authService.authStateChanges,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }
            if (snapshot.hasData) {
              PresenceService.goOnline();
              return const _LockGate(child: ChatListScreen());
            }
            return const LoginScreen();
          },
        );
      },
    );
  }
}

/// Wraps the signed-in app with a PIN check, only if App Lock is enabled.
class _LockGate extends StatefulWidget {
  final Widget child;
  const _LockGate({required this.child});

  @override
  State<_LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<_LockGate> {
  late final Future<bool> _needsUnlock = AppLockService.isEnabled();
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _needsUnlock,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final locked = snapshot.data! && !_unlocked;
        if (!locked) return widget.child;
        // A dedicated in-place PIN screen (not PinScreen, which is built to
        // be pushed and popped) — there's nothing to "pop back to" at this
        // level, so a successful unlock just flips local state instead.
        return _PinGateScreen(onUnlocked: () => setState(() => _unlocked = true));
      },
    );
  }
}

class _PinGateScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const _PinGateScreen({required this.onUnlocked});

  @override
  State<_PinGateScreen> createState() => _PinGateScreenState();
}

class _PinGateScreenState extends State<_PinGateScreen> {
  final _pinController = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    final ok = await AppLockService.verify(_pinController.text.trim());
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() => _error = 'Incorrect PIN');
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 52, color: scheme.primary),
                const SizedBox(height: 16),
                Text('Enter your PIN', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 20),
                TextField(
                  controller: _pinController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(counterText: '', labelText: 'PIN'),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 20),
                ElevatedButton(onPressed: _submit, child: const Text('Unlock')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
