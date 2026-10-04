import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/account_lifecycle_service.dart';
import '../services/app_lock_service.dart';
import '../services/auth_service.dart';
import '../services/biometric_unlock_service.dart';
import '../services/device_session_service.dart';
import '../services/duress_pin_service.dart';
import '../services/intruder_photo_service.dart';
import '../services/presence_service.dart';
import '../services/settings_service.dart';
import '../widgets/contact_developer_sheet.dart';
import 'choose_username_screen.dart';
import 'home_shell.dart';
import 'decoy_home_screen.dart';
import 'login_screen.dart';
import 'onboarding_screen.dart';
import 'reactivate_account_screen.dart';
import 'settings/forgot_password_screen.dart';
import 'suspended_account_screen.dart';
import 'vault/media_vault_screen.dart';
import '../services/local_message_store.dart';
import '../services/media_vault_service.dart';
import '../services/scheduled_message_service.dart';
import '../services/shake_detector.dart';
import 'splash_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  final _authService = AuthService();
  late final Future<_GateState> _prepared;
  bool _onboardingJustFinished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepared = _prepare();
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
      LocalMessageStore.purgeExpired();
      // Send anything scheduled that came due while the app was closed.
      ScheduledMessageService.instance.tick();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      PresenceService.goOffline();
    }
  }

  Future<_GateState> _prepare() async {
    // Feature: first-run onboarding walkthrough. Checked once here,
    // alongside the existing "stay signed in" check, rather than as a
    // separate Future — one loading spinner instead of two back-to-back.
    final hasSeenOnboarding = await SettingsService.getHasSeenOnboarding();
    final stayLoggedIn = await SettingsService.getStayLoggedIn();
    if (!stayLoggedIn) {
      await _authService.logout();
    }
    return _GateState(hasSeenOnboarding: hasSeenOnboarding, stayLoggedIn: stayLoggedIn);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_GateState>(
      future: _prepared,
      builder: (context, prefSnapshot) {
        if (!prefSnapshot.hasData) {
          return const SplashScreen();
        }
        if (!prefSnapshot.data!.hasSeenOnboarding && !_onboardingJustFinished) {
          return OnboardingScreen(onDone: () => setState(() => _onboardingJustFinished = true));
        }
        return StreamBuilder(
          stream: _authService.authStateChanges,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SplashScreen();
            }
            // BUGFIX: this used to switch to _PostAuthGate() as soon as
            // Firebase Auth reported a signed-in user. But
            // signInWithEmailAndPassword (inside LoginScreen's
            // beginEmailLogin) makes that true immediately — well before
            // an in-progress login has actually been through the
            // new-login-approval wait and claimThisDevice. That let this
            // device jump straight into the main app UI while a login
            // approval was still pending (or had just been denied/timed
            // out), racing against LoginScreen's own dialog and against
            // the self-approval bug described in
            // DeviceSessionService.claimPendingNotifier's doc comment.
            // ValueListenableBuilder here holds this on LoginScreen for
            // the entire span of a login attempt — exactly the same
            // window isClaimPending already covers for
            // watchForRemoteLogout — and only proceeds once that flag
            // flips back to false, success or not.
            return ValueListenableBuilder<bool>(
              valueListenable: DeviceSessionService.instance.claimPendingNotifier,
              builder: (context, claimPending, _) {
                if (snapshot.hasData && !claimPending) {
                  PresenceService.goOnline();
                  // BUGFIX: screens opened from the login page (Sign up, the
                  // 2-step code page, Forgot password …) are pushed ON TOP of
                  // this gate. When sign-in finished they stayed on screen —
                  // that is why a new account showed \"email already taken\"
                  // when you pressed Create again, and why 2-step login looked
                  // like it went back to the login page. Close them all.
                  return const _ClearAuthRoutes(child: _PostAuthGate());
                }
                return const LoginScreen();
              },
            );
          },
        );
      },
    );
  }
}

/// Closes every page that was opened on top of the login page the moment
/// sign-in completes, so the person lands on the home screen.
class _ClearAuthRoutes extends StatefulWidget {
  final Widget child;
  const _ClearAuthRoutes({required this.child});

  @override
  State<_ClearAuthRoutes> createState() => _ClearAuthRoutesState();
}

class _ClearAuthRoutesState extends State<_ClearAuthRoutes> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Accounts created while the old sign-up bug existed have no username.
/// This asks for one once (and only once) before showing the app, so the
/// account becomes searchable and scannable like everyone else's.
class _ProfileGate extends StatefulWidget {
  final Widget child;
  const _ProfileGate({required this.child});

  @override
  State<_ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<_ProfileGate> {
  final _auth = AuthService();
  late Future<bool> _hasName = _auth.hasUsername();

  @override
  void initState() {
    super.initState();
    // Quiet repairs (Supabase role, contacts with empty names). Never throws.
    _auth.ensureAccountReady();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _hasName,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.data == false) {
          return ChooseUsernameScreen(onDone: () => setState(() => _hasName = _auth.hasUsername()));
        }
        return widget.child;
      },
    );
  }
}

class _GateState {
  final bool hasSeenOnboarding;
  final bool stayLoggedIn;
  const _GateState({required this.hasSeenOnboarding, required this.stayLoggedIn});
}

/// Sits between "signed in" and the actual app, watching this account's
/// status LIVE the entire time the app is open — not just at sign-in.
/// That's the difference between this and a one-time check: if you (the
/// admin) suspend someone, or they deactivate from a different device,
/// while THIS device still has the app open, this drops them out of the
/// chat list and onto the correct screen immediately, without them
/// needing to close and reopen the app first.
class _PostAuthGate extends StatefulWidget {
  const _PostAuthGate();

  @override
  State<_PostAuthGate> createState() => _PostAuthGateState();
}

class _PostAuthGateState extends State<_PostAuthGate> {
  StreamSubscription<String>? _sub;
  String? _status;

  @override
  void initState() {
    super.initState();
    _sub = AccountLifecycleService.watchAccountStatus().listen((status) {
      final wasBlocked = _status == 'suspended' || _status == 'self_disabled';
      final isNowBlocked = status == 'suspended' || status == 'self_disabled';
      // BUGFIX: swapping what THIS widget renders isn't enough on its
      // own — if the person is several screens deep (an open chat,
      // settings, anywhere reached via Navigator.push), those pushed
      // routes sit ON TOP of this one in the app's single shared
      // Navigator (see main.dart's `MaterialApp(home: AuthGate())`) and
      // stay fully visible no matter what this widget switches to
      // underneath them. Only unwind the instant the account NEWLY
      // becomes blocked (not on every rebuild) so this never fights the
      // person's own in-app navigation the rest of the time.
      if (!wasBlocked && isNowBlocked) {
        navigatorKey.currentState?.popUntil((route) => route.isFirst);
      }
      if (mounted) setState(() => _status = status);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_status == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_status == 'self_disabled') {
      // No callback needed here — tapping Reactivate just writes
      // accountStatus back to 'active', and this same listener picks
      // that up on its own and swaps back to the chat list.
      return const ReactivateAccountScreen();
    }
    if (_status == 'suspended') {
      // No reactivate-from-here path — unlike self_disabled, this
      // status can only be lifted by hand, in the console (see
      // MODERATION_GUIDE.md and firestore.rules' private/profile
      // rule, which blocks the owner from ever writing it away).
      return const SuspendedAccountScreen();
    }
    return const _LockGate(child: _ProfileGate(child: HomeShell()));
  }
}

class _LockGate extends StatefulWidget {
  final Widget child;
  const _LockGate({required this.child});

  @override
  State<_LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<_LockGate> with WidgetsBindingObserver {
  late Future<bool> _needsUnlock = AppLockService.isEnabled();
  bool _unlocked = false;
  // Feature: duress/panic PIN — a THIRD state alongside locked/unlocked.
  // When true, the decoy screen renders instead of widget.child, even
  // though _unlocked is also true (entering the panic PIN still "passes"
  // the lock screen — it just leads somewhere fake).
  bool _duress = false;

  // Feature: auto-lock on idle. Separate from the backgrounding re-lock
  // above — this fires even while the app stays in the FOREGROUND, after
  // AppLockService.getIdleTimeoutMinutes() of no touch input. Off by
  // default (that getter returns null), so nothing changes for anyone
  // who hasn't turned this on in Settings.
  Timer? _idleTimer;

  // Feature: lock timing when leaving the app. Wall-clock moment the app
  // went to the background while unlocked (null while in the foreground).
  // Compared against the person's "Lock timing" setting when they return —
  // see didChangeAppLifecycleState below.
  DateTime? _pausedAt;

  // Cached copies of the two lock-timing settings, refreshed every time the
  // idle timer is (re)scheduled — i.e. on unlock and on every touch — so
  // they're always current by the time the app is left. They're cached
  // because the decision to lock has to be instant: the moment the app is
  // backgrounded, and the moment it comes back. The fail-safe default is 0 =
  // "lock immediately" until the real value has been read.
  int _graceMinutes = 0;
  int? _idleMinutesCache;

  // Feature: shake to lock + the Lock now button. _shake only exists while
  // the person has "Shake to lock" switched on; _foreground is tracked so
  // the accelerometer is never listened to while the app is in the
  // background.
  ShakeDetector? _shake;
  bool _foreground = true;

  void _onLockNowRequested() {
    if (!mounted || !_unlocked) return;
    _lockNow();
  }

  /// Feature: intruder photo. Right after a REAL unlock, clear the wrong-PIN
  /// counters and — if the front camera caught someone while the phone was
  /// locked — tell the owner, and offer to open the vault where the photo is.
  Future<void> _showIntruderNotice() async {
    final notice = await IntruderPhotoService.instance.onRealUnlock();
    if (notice == null || !mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    final openVault = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
        title: const Text('Someone tried to get in'),
        content: Text(
          '${notice.wrongAttempts == 1 ? 'A wrong PIN was entered' : '${notice.wrongAttempts} wrong PINs were entered'} '
          'while your app was locked. '
          '${notice.photosSaved == 1 ? 'A photo was' : '${notice.photosSaved} photos were'} saved in your Media vault, marked "Intruder".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Dismiss')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('See photo')),
        ],
      ),
    );
    if (openVault == true && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(settings: const RouteSettings(name: '/vault'), builder: (_) => const MediaVaultScreen()),
      );
    }
  }

  /// Starts or stops the shake detector to match the setting. Only ever
  /// running when the app lock is on, the shake switch is on, the app is
  /// unlocked, and it's in the foreground.
  Future<void> _syncShake() async {
    final lockOn = await AppLockService.isEnabled();
    final shakeOn = lockOn && await AppLockService.getShakeToLockEnabled();
    if (!mounted) return;
    if (shakeOn && _unlocked && _foreground) {
      _shake ??= ShakeDetector(onShake: _onLockNowRequested);
      _shake!.start();
    } else {
      _shake?.stop();
    }
  }

  /// A lock has to hide EVERYTHING, not just the screen underneath. The app
  /// has one shared Navigator with this gate as its home screen, so a chat,
  /// the media vault, a settings page or a photo opened on top of it would
  /// otherwise stay fully visible when this swaps to the PIN screen. So every
  /// lock path closes all open screens first (back to the home route) and
  /// re-locks the media vault.
  void _closeEverythingOpen() {
    _shake?.stop();
    MediaVaultService.instance.lock();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _scheduleIdleTimer() async {
    _idleTimer?.cancel();
    if (!_unlocked) return;
    final minutes = await AppLockService.getIdleTimeoutMinutes();
    final grace = await AppLockService.getBackgroundGraceMinutes();
    _idleMinutesCache = minutes;
    _graceMinutes = grace;
    if (minutes == null || !mounted || !_unlocked) return;
    _idleTimer = Timer(Duration(minutes: minutes), _onIdleTimeout);
  }

  void _onIdleTimeout() {
    if (!mounted) return;
    _pausedAt = null;
    _closeEverythingOpen();
    setState(() {
      _unlocked = false;
      _duress = false;
      _needsUnlock = AppLockService.isEnabled();
    });
  }

  /// Bound to every touch anywhere in the unlocked app (see the
  /// Listener wrapping widget.child/DecoyHomeScreen in build() below) —
  /// any tap, scroll, or drag pushes the idle clock back out, the same
  /// way a phone's own screen-timeout resets on touch.
  void _onUserActivity() {
    if (_unlocked) _scheduleIdleTimer();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLockService.lockNowRequests.addListener(_onLockNowRequested);
    AppLockService.lockSettingsChanged.addListener(_syncShake);
  }

  @override
  void dispose() {
    AppLockService.lockNowRequests.removeListener(_onLockNowRequested);
    AppLockService.lockSettingsChanged.removeListener(_syncShake);
    _shake?.stop();
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // BUGFIX: re-lock the moment the app is actually backgrounded, not
    // just on a full cold start. Previously, once someone entered their
    // PIN once after opening the app, _unlocked stayed true for the rest
    // of that running app session — backgrounding and returning (the
    // normal way people actually use their phone) never asked for the
    // PIN again. That defeats the entire point of an app lock on a
    // security-focused app: anyone who picked up an already-open,
    // backgrounded phone would see every chat with no prompt at all.
    //
    // Feature: lock timing. "Immediately" (the default, and what this always
    // did) still locks right here on pause. A longer setting — 1 minute, 15
    // minutes, custom… — instead just notes WHEN the app was left, and the
    // decision is made when the person comes back (the resumed branch
    // below). If Android kills the app in the meantime it starts cold, which
    // always asks for the PIN, so a longer setting can never leave a killed
    // app unlocked.
    if (state == AppLifecycleState.paused) {
      _foreground = false;
      _shake?.stop();
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
    }
    if (state == AppLifecycleState.paused && _unlocked) {
      _idleTimer?.cancel();
      if (_graceMinutes <= 0) {
        _lockNow();
      } else {
        _pausedAt = DateTime.now();
      }
    } else if (state == AppLifecycleState.resumed) {
      _resumeOrLock();
      _syncShake();
    }
  }

  /// Decided SYNCHRONOUSLY from the cached settings (see [_graceMinutes]) so
  /// there's never a moment where the chats are visible on return before the
  /// lock screen catches up.
  void _resumeOrLock() {
    final pausedAt = _pausedAt;
    if (pausedAt == null || !_unlocked) return;
    _pausedAt = null;
    // Time spent away counts as inactivity too, so if the inactivity limit
    // is SHORTER than the leave-the-app limit, the shorter one wins.
    var limitMinutes = _graceMinutes;
    final idle = _idleMinutesCache;
    if (idle != null && idle > 0 && idle < limitMinutes) {
      limitMinutes = idle;
    }
    final away = DateTime.now().difference(pausedAt);
    // A negative gap means the phone's clock was moved backwards while the
    // app was away — treat that as expired rather than trusting it.
    if (away.isNegative || away >= Duration(minutes: limitMinutes)) {
      _lockNow();
    } else {
      // Still inside the allowed window — carry on, and restart the
      // inactivity clock from now.
      _scheduleIdleTimer();
    }
  }

  void _lockNow() {
    _idleTimer?.cancel();
    _pausedAt = null;
    _closeEverythingOpen();
    setState(() {
      _unlocked = false;
      _duress = false;
      // Re-check in case app lock was just turned off in Settings —
      // don't force a PIN prompt for someone who deliberately disabled it.
      _needsUnlock = AppLockService.isEnabled();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _needsUnlock,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final locked = snapshot.data! && !_unlocked;
        if (locked) {
          return _PinGateScreen(
            onUnlocked: () {
              setState(() => _unlocked = true);
              _scheduleIdleTimer();
              _syncShake();
              _showIntruderNotice();
            },
            onDuressUnlocked: () {
              setState(() {
                _unlocked = true;
                _duress = true;
              });
              _scheduleIdleTimer();
            },
          );
        }
        return Listener(
          onPointerDown: (_) => _onUserActivity(),
          behavior: HitTestBehavior.translucent,
          child: _duress ? const DecoyHomeScreen() : widget.child,
        );
      },
    );
  }
}

class _PinGateScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  final VoidCallback onDuressUnlocked;
  const _PinGateScreen({required this.onUnlocked, required this.onDuressUnlocked});

  @override
  State<_PinGateScreen> createState() => _PinGateScreenState();
}

class _PinGateScreenState extends State<_PinGateScreen> {
  final _authService = AuthService();
  final _pinController = TextEditingController();
  String? _error;
  String? _hint;
  // Feature: biometric unlock for the app-wide PIN. _biometricReady only
  // controls whether the fingerprint button/auto-prompt shows at all —
  // the PIN field above it is NEVER removed or hidden, so a failed/
  // cancelled/unavailable biometric check always still has the normal
  // PIN entry sitting right there as the fallback.
  bool _biometricReady = false;

  @override
  void initState() {
    super.initState();
    AppLockService.getHint().then((h) {
      if (mounted) setState(() => _hint = h);
    });
    _maybeOfferBiometric();
  }

  Future<void> _maybeOfferBiometric() async {
    final enabled = await AppLockService.isBiometricEnabled();
    if (!enabled) return;
    final available = await BiometricUnlockService.isAvailable();
    if (!mounted || !available) return;
    setState(() => _biometricReady = true);
    // Auto-prompt once as soon as this screen appears — the person
    // almost always wants biometric first, not to have to tap a button
    // for it every single time they reopen the app.
    _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final ok = await BiometricUnlockService.authenticate();
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    }
    // On failure/cancel: deliberately do nothing but leave the PIN field
    // exactly as it was — no error text, since "I chose not to use
    // fingerprint right now" isn't actually an error.
  }

  Future<void> _submit() async {
    final entered = _pinController.text.trim();
    final ok = await AppLockService.verify(entered);
    if (ok) {
      widget.onUnlocked();
      return;
    }
    // Feature: duress/panic PIN. Checked only after the REAL PIN fails
    // to match — so a correct real PIN always wins even if someone had
    // also, at some point, set an identical-looking panic PIN (which
    // DuressPinService.setPin already refuses to allow in the first
    // place, but this ordering is a second, free layer of the same
    // protection).
    if (await DuressPinService.verify(entered)) {
      widget.onDuressUnlocked();
      return;
    }
    // Feature: intruder photo — counts this wrong PIN (does nothing at all
    // unless the feature is switched on in Settings > Security).
    unawaited(IntruderPhotoService.instance.onWrongPin());
    setState(() => _error = 'Incorrect PIN');
    _pinController.clear();
  }

  Future<void> _forgotPin() async {
    final controller = TextEditingController();
    bool obscure = true;
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Forgot PIN?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Confirm your account password to turn off app lock and get back in.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Account password',
                  suffixIcon: IconButton(
                    icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ForgotPasswordScreen(alsoResetAppLock: true)),
                  );
                },
                child: const Text("I've also forgotten my account password"),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
    if (password == null || password.isEmpty) return;

    try {
      await _authService.reauthenticate(password);
      await AppLockService.resetAfterAccountVerification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('App lock turned off. Set a new PIN anytime in Settings.')),
      );
      widget.onUnlocked();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Incorrect password.');
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 52, color: scheme.primary),
                const SizedBox(height: 16),
                Text('Enter your PIN', style: Theme.of(context).textTheme.titleLarge),
                if (_hint != null && _hint!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Hint: ${_hint!}', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
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
                if (_biometricReady)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton.icon(
                      onPressed: _tryBiometric,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Use biometrics'),
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton(onPressed: _forgotPin, child: const Text('Forgot PIN?')),
                TextButton.icon(
                  onPressed: () => showContactDeveloperSheet(context),
                  icon: const Icon(Icons.support_agent_outlined, size: 16),
                  label: const Text('Contact the developer'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
