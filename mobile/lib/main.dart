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
import 'services/chat_lock_service.dart';
import 'services/device_session_service.dart';
import 'services/group_service.dart';
import 'services/local_message_store.dart';
import 'services/message_relay_service.dart';
import 'services/session_service.dart';
import 'theme/app_theme.dart';
import 'screens/auth_gate.dart';
import 'screens/chat/chat_detail_screen.dart';
import 'screens/groups/group_chat_screen.dart';
import 'screens/login_approval_screen.dart';
import 'screens/security/chat_pin_guard.dart';

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
    _handleNotificationData(initialMessage.data);
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

void _handleNotificationData(Map<String, dynamic> data) {
  if (data['type'] == 'login_approval') {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final requestId = data['requestId'] as String?;
    if (uid == null || requestId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => LoginApprovalScreen(
            uid: uid,
            requestId: requestId,
            deviceLabel: data['deviceLabel'] as String? ?? 'Unknown device',
            location: data['location'] as String?,
          ),
        ),
      );
    });
    return;
  }
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
///
/// BUGFIX/feature: a hidden chat "can't be accessed anywhere" was one of
/// the explicit asks for the chat-hiding redesign — but a tapped push or
/// local notification used to jump straight into ChatDetailScreen/
/// GroupChatScreen regardless of hidden status, which was a real way
/// around the hide code entirely (whoever's holding the unlocked phone
/// just taps the notification). Now checked first and silently refused —
/// no error, no toast, nothing that would itself reveal a hidden chat
/// exists — the app just comes to the foreground without navigating
/// anywhere. The person still gets to it the normal way: their hide code
/// typed into search.
///
/// Same reasoning applies to "Lock this chat" — a locked chat isn't
/// hidden (it still shows in the list normally), but a notification tap
/// still shouldn't be a way around its PIN. Unlike the hidden check
/// above, a locked chat SHOULD still open — just behind the PIN prompt —
/// since locking was never meant to hide that the chat exists.
void _openChat({required String conversationId, required String peerUid, required String peerUsername}) {
  // Post-frame so this is safe even if it fires before the first widget
  // tree (e.g. cold start) has finished building.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (await ChatLockService.isHidden(conversationId)) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;
    if (!await requireChatPinIfLocked(context, conversationId)) return;
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
    GroupService.instance.retryAllPendingResends();
    sweepTimer?.cancel();
    sweepTimer = Timer.periodic(const Duration(seconds: 30), (_) => LocalMessageStore.purgeExpired());

    // Single-active-device enforcement (see DeviceSessionService): if a
    // different device claims this account (a real new login elsewhere,
    // not this same device reconnecting), sign this one out immediately
    // with a clear explanation instead of silently leaving two devices
    // both able to act on the account.
    DeviceSessionService.instance.watchForRemoteLogout(user.uid, () async {
      // BUGFIX: without this, someone several screens deep (an open
      // chat, settings, anywhere reached via Navigator.push) would get
      // signed out underneath whatever they were looking at, but that
      // screen would stay fully visible — it sits ON TOP of AuthGate in
      // the app's one shared Navigator (see `MaterialApp(home:
      // AuthGate())` below), and swapping what's underneath a still-open
      // route doesn't make that route go away on its own.
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
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

    _watchForIncomingLoginApprovals(user.uid);
  });
}

/// Feature: new-login accept/deny flow (see AccountSecurityScreen's
/// "Require approval for new logins" toggle). While this device is the
/// signed-in/active one AND in the foreground, this pops the Accept/Deny
/// screen the instant a new login requests approval — no need to wait for
/// the push notification, which only matters if the app is backgrounded
/// or killed (see _handleNotificationData above for that path).
String? _lastHandledApprovalRequestId;
void _watchForIncomingLoginApprovals(String uid) {
  DeviceSessionService.instance.watchPendingApprovalRequest(uid).listen(
    (request) async {
      if (request == null) return;
      final requestId = request['requestId'] as String?;
      if (requestId == null || requestId == _lastHandledApprovalRequestId) return;
      // BUGFIX: this listener is (re)started the instant Firebase Auth
      // reports a signed-in user — which fires the moment
      // signInWithEmailAndPassword succeeds inside beginEmailLogin, well
      // before THIS SAME device (if it's the one currently logging in)
      // has gone on to create its own approval request and finish
      // claiming itself. Without this check, a device could catch the
      // pending request it had just created about itself and pop the
      // "approve this login" screen on itself — asking the person to
      // approve their own sign-in. Racing that self-prompt against
      // LoginScreen's own approval wait is what caused needing to
      // accept/deny several times before a login actually went through.
      // A device must never be asked to approve its own login.
      final myDeviceId = await DeviceSessionService.instance.localDeviceId();
      if (request['requestingDeviceId'] == myDeviceId) return;
      _lastHandledApprovalRequestId = requestId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => LoginApprovalScreen(
              uid: uid,
              requestId: requestId,
              deviceLabel: request['requestingDeviceLabel'] as String? ?? 'Unknown device',
              location: request['requestingLocation'] as String?,
            ),
          ),
        );
      });
    },
    // BUGFIX: this used to have no error handler at all, so a query
    // failure (e.g. the missing-composite-index issue this same fix
    // resolves — see watchPendingApprovalRequest's own doc comment) died
    // completely silently: no crash, no log, the active device's "new
    // login wants approval" screen just never showed up, with nothing
    // anywhere pointing at why. debugPrint at minimum makes a future
    // failure of this listener, for any reason, visible in the device
    // log instead of invisible.
    onError: (Object e) => debugPrint('watchPendingApprovalRequest error: $e'),
  );
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
    final data = message.data;
    // The OLD device's live Firestore listener (see
    // _watchForIncomingLoginApprovals below) already pops the
    // Accept/Deny screen the instant a request appears while this app is
    // foregrounded — showing a system notification for it too here would
    // just be a redundant second alert for the same thing.
    if (data['type'] == 'login_approval') return;
    final notification = message.notification;
    if (notification == null) return;
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
    _handleNotificationData(message.data);
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
