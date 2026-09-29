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
import 'services/app_badge_service.dart';
import 'services/auth_service.dart';
import 'services/device_session_service.dart';
import 'services/group_service.dart';
import 'services/inactivity_wipe_service.dart';
import 'services/keyword_mute_service.dart';
import 'services/local_message_store.dart';
import 'services/live_location_service.dart';
import 'services/message_relay_service.dart';
import 'services/scheduled_message_service.dart';
import 'services/media_vault_service.dart';
import 'services/private_keyboard_service.dart';
import 'services/screenshot_guard_service.dart';
import 'services/settings_service.dart';
import 'services/session_service.dart';
import 'services/story_service.dart';
import 'services/traffic_camouflage_service.dart';
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
    // SECURITY FIX (audit, 2026-09-24): before this, every request to
    // Supabase — including message_relay — went out under the bare anon
    // key with NO Supabase-side identity at all, because this app never
    // calls Supabase's own auth.signIn (it uses Firebase Auth as its one
    // real identity system). That meant a Postgres RLS policy based on
    // auth.uid() had NOTHING to check — auth.uid() was always null — so
    // message_relay could only ever have been protected by a fully open
    // policy (or a still-open-by-default table if RLS was never turned
    // on for it at all), not a real per-user one, however carefully its
    // policy text was written.
    //
    // This wires Supabase's documented "Third-Party Auth" mechanism to
    // this app's actual identity: on every request, the Supabase SDK
    // calls this function and sends whatever it returns as the bearer
    // token, instead of the plain anon key. Returning the current
    // Firebase user's own ID token means Postgres's auth.uid() now
    // resolves to their real Firebase uid — the same string already
    // stored in every sender_uid/recipient_uid column — so a normal
    // `auth.uid()::text = recipient_uid` RLS policy (see
    // supabase/migrations/0008_message_relay_rls.sql) finally has
    // something real to check against.
    //
    // Returning null when signed out is fine and expected — it just
    // means those requests go out anonymously, exactly as they always
    // have (nothing here narrows what a signed-out user could already
    // do). This has NO effect until the matching dashboard step is done:
    // Authentication > Third-Party Auth > add this app's Firebase
    // project, and its RLS policies are applied — see that migration
    // file's own header comment for the full, honest picture, including
    // the one piece (giving every Firebase user Supabase's required
    // `role: 'authenticated'` claim) that still needs a small privileged
    // service built separately, not just this client change.
    accessToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
  );
  await LocalMessageStore.init();
  // Feature: live location sharing — resumes pushing position updates for
  // a share that was still running when the app was last closed, instead
  // of leaving it silently stale. Safe to call even when signed out or
  // when there's nothing to resume — see the method's own doc comment.
  LiveLocationService.resumeActiveShareIfAny();

  // Screenshot alert: lets the native side (MainActivity.kt) report screenshot
  // attempts up to Dart. Recents preview: applies the saved "Hide app preview
  // in recent apps" choice (on by default). Private keyboard: loads its saved
  // choice (off by default). Vault: clears any decrypted temp copies a
  // previous run might have left behind.
  ScreenshotGuardService.init();
  ScreenshotGuardService.setRecentsPreviewHidden(await SettingsService.getHideRecentsPreview());
  await PrivateKeyboardService.load();
  MediaVaultService.instance.cleanTemp();

  // If a session is already persisted from a previous run (the normal
  // "reopen the app" case), get this device's crypto keys ready BEFORE the
  // first frame renders — SessionService also checks whether this uid
  // matches whoever last used this device, and wipes any stale
  // account's local state first if not (see session_service.dart).
  final existingUser = FirebaseAuth.instance.currentUser;
  if (existingUser != null) {
    await SessionService.prepareForUser(existingUser.uid);
    await LocalMessageStore.purgeExpired();
    await InactivityWipeService.sweep();
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
    // Same checks and same one-screen-per-request guard as the live
    // listener — a tapped notification can no longer stack a second copy.
    _presentLoginApproval(
      uid: uid,
      requestId: requestId,
      deviceLabel: data['deviceLabel'] as String?,
      location: data['location'] as String?,
    );
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
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final isGroup = conversationId.startsWith('group_');
    // BUGFIX: also now covers paused chats, not just hidden/locked ones —
    // see chat_pin_guard.dart's canOpenChat. A paused chat shouldn't
    // generate a new-message notification in the first place (sending is
    // blocked while frozen), but a delayed/stale one reaching here
    // shouldn't be a way back in either.
    if (!await canOpenChat(context, conversationId: conversationId, otherUid: isGroup ? null : peerUid)) return;
    if (isGroup) {
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
      TrafficCamouflageService.instance.stop();
      ScheduledMessageService.instance.stop();
      GroupService.instance.stopCaching();
      DeviceSessionService.instance.stopWatching();
      _approvalWatchSub?.cancel();
      _approvalWatchSub = null;
      sweepTimer?.cancel();
      // Feature: app-icon badge — never leave one account's unread count on
      // the icon after that account has signed out.
      AppBadgeService.instance.clear();
      return;
    }
    // BUGFIX (login approval): if this is a login still waiting for the old
    // phone's approval, hold off — don't publish keys, start pulling
    // messages, or start watching for approvals until it has really finished.
    // If it was denied / cancelled / timed out, the user is signed out again
    // by then and there is nothing to set up.
    if (DeviceSessionService.instance.isClaimPending) {
      await _waitForClaimToSettle();
      if (FirebaseAuth.instance.currentUser?.uid != user.uid) return;
    }
    await SessionService.prepareForUser(user.uid);
    await LocalMessageStore.purgeExpired();
    // Feature: Stories — best-effort cleanup of MY OWN expired stories'
    // Supabase Storage files (see StoryService.purgeMyExpiredStories for
    // why this can't just rely on Firestore's TTL policy alone).
    unawaited(StoryService.instance.purgeMyExpiredStories());
    await MessageRelayService.start();
    // Feature: traffic pattern camouflage — starts the randomized decoy
    // scheduler (no-op each round unless the person has actually turned
    // camouflage on somewhere — see TrafficCamouflageService).
    TrafficCamouflageService.instance.start(user.uid);
    // Feature: send later — starts the timer that sends scheduled messages
    // when they come due (see ScheduledMessageService for its limits).
    ScheduledMessageService.instance.start();
    GroupService.instance.startCaching();
    GroupService.instance.retryAllPendingResends();
    sweepTimer?.cancel();
    sweepTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      LocalMessageStore.purgeExpired();
    });
    // Feature: Stories — separate, less frequent sweep (expired stories
    // don't need the same 30s responsiveness disappearing messages do;
    // Firestore's own TTL policy is already handling the metadata side
    // on whatever schedule it runs — this only speeds up the Storage
    // file cleanup and covers the same ground redundantly, which is fine
    // since deleting an already-deleted doc/file is a harmless no-op).
    Timer.periodic(const Duration(minutes: 15), (_) => StoryService.instance.purgeMyExpiredStories());

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

    // Feature: multiple devices (off by default) — the counterpart to the
    // eviction watcher above. Fires only if THIS specific device is
    // deliberately removed (by itself, or from another of the person's own
    // devices in Account security > Multiple devices) — never just because
    // another device is also signed in, which is the whole point of the
    // feature being on. A no-op subscription on any account that hasn't
    // turned this on.
    DeviceSessionService.instance.watchForRevocation(user.uid, () async {
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
      await AuthService().logout();
      final context = navigatorKey.currentContext;
      if (context == null) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Device removed'),
          content: const Text(
            'This device was removed from your account from another signed-in device. If this wasn\'t you, change your '
            'password right away from Account Security after signing back in.',
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
StreamSubscription? _approvalWatchSub;

/// Waits (up to 3 minutes, as a safety net) until a login attempt that is
/// still in progress on THIS phone has fully finished or been abandoned.
///
/// BUGFIX (login approval): the sign-in listeners in this file used to start
/// the moment Firebase accepted the password — before the old phone had
/// approved anything — and immediately published this phone's encryption
/// keys, started pulling the account's queued messages and registered this
/// phone for the account's push notifications. That happened even if the
/// login was then denied or timed out. Everything that should only follow a
/// COMPLETED sign-in now waits here first.
Future<void> _waitForClaimToSettle() async {
  final notifier = DeviceSessionService.instance.claimPendingNotifier;
  if (!notifier.value) return;
  final completer = Completer<void>();
  void listener() {
    if (!notifier.value && !completer.isCompleted) completer.complete();
  }

  notifier.addListener(listener);
  try {
    await completer.future.timeout(const Duration(minutes: 3));
  } catch (_) {
    // Safety net only — fall through rather than block forever.
  } finally {
    notifier.removeListener(listener);
  }
}

/// The ONE place a login-approval screen is ever put on screen — used by the
/// live listener below AND by tapped notifications, so they can't both show
/// the same request.
///
/// A request is shown only if ALL of these hold (each one fixes a specific
/// glitch that was reported):
///  * this phone isn't itself in the middle of signing in;
///  * this phone IS the account's active device — a phone that isn't active
///    has no business answering, which stops phantom prompts on a phone that
///    was just reinstalled or is still signing in;
///  * the request is still pending and still fresh (not an abandoned old
///    attempt);
///  * it wasn't created by this very phone;
///  * no other screen is already showing it.
Future<void> _presentLoginApproval({
  required String uid,
  required String requestId,
  String? deviceLabel,
  String? location,
}) async {
  final sessions = DeviceSessionService.instance;
  try {
    if (sessions.isClaimPending) return;
    if (!await sessions.isThisDeviceActive(uid)) return;
    final request = await sessions.getApprovalRequest(uid, requestId);
    if (request == null || request['status'] != 'pending') return;
    if (!sessions.isApprovalFresh(request)) return;
    if (request['requestingDeviceId'] == await sessions.localDeviceId()) return;
    if (!sessions.tryMarkApprovalPresented(requestId)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = navigatorKey.currentState;
      if (nav == null) {
        sessions.unmarkApprovalPresented(requestId);
        return;
      }
      nav.push(
        MaterialPageRoute(
          builder: (_) => LoginApprovalScreen(
            uid: uid,
            requestId: requestId,
            deviceLabel: (request['requestingDeviceLabel'] as String?) ?? deviceLabel ?? 'Unknown device',
            location: (request['requestingLocation'] as String?) ?? location,
            // Feature: number matching. Null for a request from an older app
            // build that doesn't send one — the screen falls back to plain
            // Accept / Deny in that case.
            matchNumber: (request['matchNumber'] as num?)?.toInt(),
          ),
        ),
      );
    });
  } catch (e) {
    debugPrint('_presentLoginApproval error: $e');
  }
}

void _watchForIncomingLoginApprovals(String uid) {
  // BUGFIX: this used to start a NEW listener on every sign-in and never
  // stop the old ones, so listeners piled up. There is only ever one now.
  _approvalWatchSub?.cancel();
  _approvalWatchSub = DeviceSessionService.instance.watchPendingApprovalRequest(uid).listen(
    (request) {
      if (request == null) return;
      final requestId = request['requestId'] as String?;
      if (requestId == null) return;
      _presentLoginApproval(
        uid: uid,
        requestId: requestId,
        deviceLabel: request['requestingDeviceLabel'] as String?,
        location: request['requestingLocation'] as String?,
      );
    },
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
    // BUGFIX (login approval): don't register THIS phone for the account's
    // push notifications until its sign-in has really been approved and
    // finished — otherwise a login that is still waiting (or gets denied)
    // would already be receiving the account's notifications, including
    // the approval request about ITSELF.
    if (DeviceSessionService.instance.isClaimPending) {
      await _waitForClaimToSettle();
      if (FirebaseAuth.instance.currentUser?.uid != user.uid) return;
    }
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
  FirebaseMessaging.onMessage.listen((message) async {
    final data = message.data;
    // The OLD device's live Firestore listener (see
    // _watchForIncomingLoginApprovals below) already pops the
    // Accept/Deny screen the instant a request appears while this app is
    // foregrounded — showing a system notification for it too here would
    // just be a redundant second alert for the same thing.
    if (data['type'] == 'login_approval') return;
    final notification = message.notification;
    if (notification == null) return;
    // Feature: mute by keyword. Best-effort — see KeywordMuteService's
    // doc comment for exactly why this only works while the app is
    // alive, and why it's a race against the realtime decrypt-and-store
    // path rather than a guarantee. If nothing's been stored yet for
    // this conversation (race lost, or this is a media/system message
    // with nothing text-based to check), the notification just shows
    // normally — muting only ever SUPPRESSES on a confirmed keyword
    // match, never on uncertainty.
    final conversationId = data['conversationId'] as String?;
    if (conversationId != null) {
      final latest = await LocalMessageStore.getLatestMessage(conversationId);
      if (latest != null && latest.messageType == 'text' && await KeywordMuteService.isMuted(conversationId, latest.text)) {
        return;
      }
    }
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
      title: 'NWisp Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(branding.accentColor),
      darkTheme: AppTheme.dark(branding.accentColor),
      themeMode: themeService.mode,
      // Appearance > Font size. Multiplies whatever text size the phone
      // itself already asks for, so system accessibility settings still work.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final base = media.textScaler.scale(1.0);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(base * themeService.fontScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AuthGate(),
    );
  }
}
