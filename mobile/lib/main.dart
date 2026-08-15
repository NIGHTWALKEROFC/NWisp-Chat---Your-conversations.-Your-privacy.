import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'services/theme_service.dart';
import 'services/branding_service.dart';
import 'services/auth_service.dart';
import 'services/crypto_service.dart';
import 'services/local_message_store.dart';
import 'services/message_relay_service.dart';
import 'theme/app_theme.dart';
import 'screens/auth_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  await LocalMessageStore.init();

  // If a session is already persisted from a previous run (the normal
  // "reopen the app" case), get this device's crypto keys ready BEFORE the
  // first frame renders. Previously this only happened inside the
  // post-runApp auth listener below, which raced with the chat list's very
  // first read of the local message store: decryptLocal() needs
  // _localStorageKey, which hadn't loaded yet, so that first summary load
  // silently failed (see the added error handling in LocalMessageStore too)
  // and the home screen was stuck on its loading spinner until some other
  // write — like sending a message — triggered a second, successful reload.
  final existingUser = FirebaseAuth.instance.currentUser;
  if (existingUser != null) {
    await CryptoService.ensureIdentityKeyPair();
    await CryptoService.ensureLocalStorageKey();
    await LocalMessageStore.purgeExpired();
  }

  final themeService = ThemeService();
  await themeService.load();
  final brandingService = BrandingService();
  await brandingService.load();

  _setUpPushNotifications();
  _setUpMessagingLifecycle();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeService),
        ChangeNotifierProvider.value(value: brandingService),
      ],
      child: const SecureChatApp(),
    ),
  );
}

/// Starts/stops the Supabase message relay listener and local key setup
/// whenever the Firebase auth state changes, and runs a light periodic
/// sweep to delete any local messages whose auto-delete timer has expired
/// while the app is in the foreground (see the "disappearing messages"
/// note in the writeup for the background-execution caveat).
///
/// ensureIdentityKeyPair/ensureLocalStorageKey are idempotent (they just
/// load the existing key if one's already there), so re-running them here
/// for the same user main() already prepared above is harmless — this
/// listener is what matters for actual sign-in/sign-out transitions.
void _setUpMessagingLifecycle() {
  Timer? sweepTimer;
  FirebaseAuth.instance.authStateChanges().listen((user) async {
    if (user == null) {
      MessageRelayService.stop();
      sweepTimer?.cancel();
      return;
    }
    await CryptoService.ensureIdentityKeyPair();
    await CryptoService.ensureLocalStorageKey();
    await LocalMessageStore.purgeExpired();
    await MessageRelayService.start();
    sweepTimer?.cancel();
    sweepTimer = Timer.periodic(const Duration(seconds: 30), (_) => LocalMessageStore.purgeExpired());
  });
}

void _setUpPushNotifications() {
  FirebaseMessaging.instance.requestPermission();
  FirebaseAuth.instance.authStateChanges().listen((user) async {
    if (user == null) return;
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await AuthService().saveFcmToken(token);
    }
  });
  FirebaseMessaging.onMessage.listen((message) {
    // Foreground pushes land here; background/terminated pushes get a
    // system notification automatically once a Cloud Function is sending
    // them (still a follow-up item, see suggestions).
  });
}

class SecureChatApp extends StatelessWidget {
  const SecureChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeService = context.watch<ThemeService>();
    final branding = context.watch<BrandingService>();
    return MaterialApp(
      title: 'Secure Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(branding.accentColor),
      darkTheme: AppTheme.dark(branding.accentColor),
      themeMode: themeService.mode,
      home: const AuthGate(),
    );
  }
}
