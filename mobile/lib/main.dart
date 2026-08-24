import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'services/theme_service.dart';
import 'services/branding_service.dart';
import 'services/auth_service.dart';
import 'services/device_session_service.dart';
import 'services/group_service.dart';
import 'services/local_message_store.dart';
import 'services/message_relay_service.dart';
import 'services/session_service.dart';
import 'theme/app_theme.dart';
import 'screens/auth_gate.dart';
import 'screens/chat/chat_detail_screen.dart';
import 'screens/groups/group_chat_screen.dart';

/// Used to navigate to a chat from a tapped push notification, from
/// anywhere — including before AuthGate has even built a Navigator the
/// normal widget-tree way (e.g. a cold start from a terminated-state tap).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
const _androidChannel = AndroidNotificationChannel(
  'messages',
  'Messages',
  description: 'New message notifications',
  importance: Importance.high,
);

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
  // first frame renders — SessionService also checks whether this uid
  // matches whoever last used this device, and wipes any stale
  // account's local state first if not (see session_service.dart).
  final existingUser = FirebaseAuth.instance.currentUser;
  if (existingUser != null) {
    await SessionService.prepareForUser(existingUser.uid);
    await LocalMessageStore.purgeExpired();
  }

  final themeService = ThemeService();
  await themeService.load();
  final brandingService = BrandingService();
  await brandingService.load();

  await _setUpLocalNotifications();
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

  // If the app was cold-started BY tapping a notification (fully
  // terminated, not just backgrounded), handle that tap once the app is up.
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    _openChatFromNotificationData(initialMessage.data);
  }
}

Future<void> _setUpLocalNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  await _localNotifications.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      final parts = payload.split('|'); // conversationId|peerUid|peerUsername
      if (parts.length < 3) return;
      _openChat(conversationId: parts[0], peerUid: parts[1], peerUsername: parts.sublist(2).join('|'));
    },
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_androidChannel);
}

void _openChatFromNotificationData(Map<String, dynamic> data) {
  final conversationId = data['conversationId'] as String?;
  final peerUid = data['senderUid'] as String?;
  final peerUsername = data['senderUsername'] as String?;
  if (conversationId == null || peerUid == null) return;
  _openChat(conversationId: conversationId, peerUid: peerUid, peerUsername: peerUsername ?? 'Chat');
}

/// Group ids are always "group_<uuid>" (see GroupService.newGroupId) — a
/// tapped push/local notification for a group message routes to
/// GroupChatScreen instead of the 1:1 ChatDetailScreen. [peerUid] is
/// unused in that branch (the group screen resolves its own member list
/// from Firestore) but is still required by the shared call sites above.
void _openChat({required String conversationId, required String peerUid, required String peerUsername}) {
  // Post-frame so this is safe even if it fires before the first widget
  // tree (e.g. cold start) has finished building.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (conversationId.startsWith('group_')) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: conversationId)),
      );
      return;
    }
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(
          conversationId: conversationId,
          peerUid: peerUid,
          peerUsername: peerUsername,
        ),
      ),
    );
  });
}

/// Starts/stops the Supabase message relay listener, the group-metadata
/// cache, and local session setup whenever the Firebase auth state
/// changes, and runs a light periodic sweep to delete any local messages
/// whose auto-delete timer has expired while the app is in the foreground
/// (see the "disappearing messages" note in the writeup for the
/// background-execution caveat).
///
/// SessionService.prepareForUser is idempotent for a given uid (it just
/// reloads existing keys once the account matches), so re-running it here
/// for the same user main() already prepared above is harmless — this
/// listener is what matters for actual sign-in/sign-out/account-switch
/// transitions.
void _setUpMessagingLifecycle() {
  Timer? sweepTimer;
  FirebaseAuth.instance.authStateChanges().listen((user) async {
    if (user == null) {
      MessageRelayService.stop();
      GroupService.instance.stopCaching();
      DeviceSessionService.instance.stopWatching();
      sweepTimer?.cancel();
      return;
    }
    await SessionService.prepareForUser(user.uid);
    await LocalMessageStore.purgeExpired();
    await MessageRelayService.start();
    GroupService.instance.startCaching();
    sweepTimer?.cancel();
    sweepTimer = Timer.periodic(const Duration(seconds: 30), (_) => LocalMessageStore.purgeExpired());

    // Single-active-device enforcement (see DeviceSessionService): if a
    // different device claims this account (a real new login elsewhere,
    // not this same device reconnecting), sign this one out immediately
    // with a clear explanation instead of silently leaving two devices
    // both able to act on the account.
    DeviceSessionService.instance.watchForRemoteLogout(user.uid, () async {
      await AuthService().logout();
      final context = navigatorKey.currentContext;
      if (context == null) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Signed out'),
          content: const Text(
            'Your account was signed in on another device, so this device has been '
            'signed out for your security. If this wasn\'t you, change your password '
            'right away from Account Security after signing back in.',
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK')),
          ],
        ),
      );
    });
  });
}

void _setUpPushNotifications() {
  FirebaseMessaging.instance.requestPermission();

  // Register this device's token whenever we're signed in, AND whenever
  // Firebase silently rotates the token (app reinstall, OS-level refresh,
  // etc) — the old code never listened for that, so a rotated token meant
  // this device quietly stopped receiving pushes until the next full
  // sign-in.
  FirebaseAuth.instance.authStateChanges().listen((user) async {
    if (user == null) return;
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await AuthService().saveFcmToken(token);
    }
  });
  FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
    if (FirebaseAuth.instance.currentUser != null) {
      await AuthService().saveFcmToken(token);
    }
  });

  // Foreground: FCM does NOT show a system notification automatically while
  // the app is open, so build one ourselves via flutter_local_notifications.
  FirebaseMessaging.onMessage.listen((message) {
    final notification = message.notification;
    if (notification == null) return;
    final data = message.data;
    final payload = [
      data['conversationId'] ?? '',
      data['senderUid'] ?? '',
      data['senderUsername'] ?? 'Chat',
    ].join('|');
    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: payload,
    );
  });

  // App was backgrounded (not terminated) and the user tapped the system
  // notification to bring it back to the foreground.
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    _openChatFromNotificationData(message.data);
  });
}

class SecureChatApp extends StatelessWidget {
  const SecureChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeService = context.watch<ThemeService>();
    final branding = context.watch<BrandingService>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Secure Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(branding.accentColor),
      darkTheme: AppTheme.dark(branding.accentColor),
      themeMode: themeService.mode,
      home: const AuthGate(),
    );
  }
}
