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
import 'theme/app_theme.dart';
import 'screens/auth_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
  );

  final themeService = ThemeService();
  await themeService.load();
  final brandingService = BrandingService();
  await brandingService.load();

  _setUpPushNotifications();

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

/// Requests notification permission and saves this device's FCM token to
/// the user's profile whenever they're signed in. This is the client-side
/// half only — actually delivering a push when the app is closed needs a
/// small server-side Cloud Function that reads these tokens, a separate
/// follow-up (nothing more to add here on the Flutter side).
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
    // Foreground messages arrive here; the OS shows a system notification
    // automatically for background/terminated messages. In-app banners
    // for foreground messages can be added once there's a UI spot for them.
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
