import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../models/local_message.dart';
import '../services/call_log_service.dart';
import '../services/contact_service.dart';
import '../services/call_service.dart';
import '../services/group_call_service.dart';
import '../services/incoming_call_notifier.dart';
import '../services/group_service.dart';
import '../services/secret_chat_service.dart';
import '../services/home_sections_service.dart';
import '../services/local_message_store.dart';
import 'announcements_screen.dart';
import 'chat_list_screen.dart';
import 'call/call_screens.dart';
import 'community/community_screen.dart';
import 'nearby/nearby_screen.dart';
import 'secret/secret_chat_screen.dart';
import 'settings/settings_screen.dart';
import 'stories/stories_tab_screen.dart';

/// The app's home: a bottom bar with WhatsApp-style sections.
///
///  * Chats — always there (direct chats and normal groups).
///  * Announcements — groups where only admins can post. Appears only when
///    you are in at least one, and can be switched off in Settings > Chats.
///  * Community — public communities anyone can find and join. Can also be
///    switched off in Settings > Chats.
///
/// Each section is its own screen with its own top bar; this widget only
/// owns the bottom bar, the unread dots, and which section is showing.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool _ready = false;
  String _current = 'chats';

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _groupDocs = [];
  List<ConversationSummary> _summaries = [];
  StreamSubscription? _groupsSub;
  StreamSubscription? _summarySub;
  // Feature: number of contact requests waiting for an answer (badge on Chats).
  StreamSubscription<int>? _requestsSub;
  int _pendingRequests = 0;

  // Feature: incoming voice calls and secret-chat invitations. Both only
  // work while the app is open (that's the point of a secret chat, and
  // calls also get a push — see CallService).
  Route<void>? _callRoute;
  String? _callRouteId;
  Route<void>? _inviteRoute;
  String? _inviteRouteId;

  Route<void>? _groupRoute;
  String? _groupRouteId;

  Future<void> _answerDirect(IncomingCall call) async {
    final nav = Navigator.of(context);
    try {
      final session = await CallService.instance.acceptCall(call);
      nav.push(MaterialPageRoute(builder: (_) => VoiceCallScreen(session: session)));
    } catch (_) {
      await CallService.instance.declineCall(call);
    }
  }

  void _onIncomingGroupCall() {
    final call = GroupCallService.instance.incoming.value;
    if (call != null) {
      if (_groupRoute != null && _groupRoute!.isActive) return;
      // "Answer" was pressed on the notification: go straight in.
      if (IncomingCallNotifier.pendingJoinGroupCallId == call.callId) {
        IncomingCallNotifier.pendingJoinGroupCallId = null;
        GroupCallService.instance.join(call).then((s) {
          if (mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupCallScreen(session: s)));
        }).catchError((_) {});
        return;
      }
      IncomingCallNotifier.showOverLockScreen(true);
      final route = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => GroupIncomingCallScreen(call: call));
      _groupRoute = route;
      _groupRouteId = call.callId;
      navigator_().push(route);
    } else if (_groupRoute != null && _groupRoute!.isActive && GroupCallService.instance.handledCallId != _groupRouteId) {
      navigator_().removeRoute(_groupRoute!);
      _groupRoute = null;
      IncomingCallNotifier.cancelRing();
      IncomingCallNotifier.showOverLockScreen(false);
    }
  }

  void _onIncomingCall() {
    final call = CallService.instance.incoming.value;
    if (call != null) {
      if (_callRoute != null && _callRoute!.isActive) return;
      // "Answer" was pressed on the notification: answer straight away.
      if (IncomingCallNotifier.pendingAnswerCallId == call.callId) {
        IncomingCallNotifier.pendingAnswerCallId = null;
        _answerDirect(call);
        return;
      }
      IncomingCallNotifier.showOverLockScreen(true);
      final route = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => IncomingCallScreen(call: call));
      _callRoute = route;
      _callRouteId = call.callId;
      navigator_().push(route);
    } else if (_callRoute != null && _callRoute!.isActive && CallService.instance.handledCallId != _callRouteId) {
      // The caller hung up before we answered — note it as a missed call.
      navigator_().removeRoute(_callRoute!);
      _callRoute = null;
      IncomingCallNotifier.cancelRing();
      IncomingCallNotifier.showOverLockScreen(false);
      CallLogService.instance.syncMissed();
    }
  }

  void _onSecretInvite() {
    final invite = SecretChatService.instance.incomingInvite.value;
    if (invite != null) {
      if (_inviteRoute != null && _inviteRoute!.isActive) return;
      final route = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => SecretInviteScreen(invite: invite));
      _inviteRoute = route;
      _inviteRouteId = invite.chatId;
      navigator_().push(route);
    } else if (_inviteRoute != null && _inviteRoute!.isActive && SecretChatService.instance.handledInviteId != _inviteRouteId) {
      navigator_().removeRoute(_inviteRoute!);
      _inviteRoute = null;
    }
  }

  NavigatorState navigator_() => Navigator.of(context);

  @override
  void initState() {
    super.initState();
    HomeSectionsService.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
    HomeSectionsService.announcementsTab.addListener(_onSettingChanged);
    HomeSectionsService.communityTab.addListener(_onSettingChanged);
    HomeSectionsService.nearbyTab.addListener(_onSettingChanged);
    CallService.instance.incoming.addListener(_onIncomingCall);
    GroupCallService.instance.incoming.addListener(_onIncomingGroupCall);
    SecretChatService.instance.incomingInvite.addListener(_onSecretInvite);
    CallService.instance.startListening();
    GroupCallService.instance.startListening();
    // Calls that rang while NWisp was closed become "Missed voice call" lines.
    CallLogService.instance.syncMissed();
    SecretChatService.instance.startListening();
    _groupsSub = GroupService.instance.myGroupsStream().listen((snap) {
      if (mounted) setState(() => _groupDocs = snap.docs);
    });
    _requestsSub = ContactService().pendingRequestCountStream().listen((n) {
      if (mounted) setState(() => _pendingRequests = n);
    });
    _summarySub = LocalMessageStore.watchSummaries().listen((list) {
      if (mounted) setState(() => _summaries = list);
    });
  }

  void _onSettingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HomeSectionsService.announcementsTab.removeListener(_onSettingChanged);
    HomeSectionsService.communityTab.removeListener(_onSettingChanged);
    HomeSectionsService.nearbyTab.removeListener(_onSettingChanged);
    CallService.instance.incoming.removeListener(_onIncomingCall);
    GroupCallService.instance.incoming.removeListener(_onIncomingGroupCall);
    SecretChatService.instance.incomingInvite.removeListener(_onSecretInvite);
    CallService.instance.stopListening();
    GroupCallService.instance.stopListening();
    SecretChatService.instance.stopListening();
    _groupsSub?.cancel();
    _summarySub?.cancel();
    _requestsSub?.cancel();
    super.dispose();
  }

  int _unreadWhere(bool Function(Map<String, dynamic> data) test) {
    final ids = <String>{};
    for (final d in _groupDocs) {
      if (test(d.data())) ids.add(d.id);
    }
    var total = 0;
    for (final s in _summaries) {
      if (ids.contains(s.conversationId)) total += s.unreadCount;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final hasAnnouncementGroups = _groupDocs.any((d) => d.data()['onlyAdminsCanSend'] == true && d.data()['isCommunity'] != true);
    final showAnnouncements = HomeSectionsService.announcementsTab.value && hasAnnouncementGroups;
    final showCommunity = HomeSectionsService.communityTab.value;
    final showNearby = HomeSectionsService.nearbyTab.value;

    final tabs = <_Tab>[
      const _Tab('chats', 'Chats', Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
      const _Tab('stories', 'Stories', Icons.auto_awesome_motion_outlined, Icons.auto_awesome_motion),
      if (showAnnouncements) const _Tab('announcements', 'Announcements', Icons.campaign_outlined, Icons.campaign),
      if (showCommunity) const _Tab('community', 'Community', Icons.groups_2_outlined, Icons.groups_2),
      // Feature: Nearby chat (Bluetooth / Wi-Fi, no internet). Can be switched off in Settings > Chats.
      if (showNearby) const _Tab('nearby', 'Nearby', Icons.bluetooth_searching_rounded, Icons.bluetooth_connected_rounded),
      // Feature: Settings lives in the bottom bar (Telegram-style), so the
      // 3-dot menu on Chats only needs the everyday actions.
      const _Tab('settings', 'Settings', Icons.settings_outlined, Icons.settings),
    ];
    if (!tabs.any((t) => t.id == _current)) _current = 'chats';
    final index = tabs.indexWhere((t) => t.id == _current);

    final unreadAnnouncements = _unreadWhere((d) => d['onlyAdminsCanSend'] == true && d['isCommunity'] != true);
    final unreadCommunity = _unreadWhere((d) => d['isCommunity'] == true);

    int badgeFor(String id) =>
        id == 'announcements' ? unreadAnnouncements : (id == 'community' ? unreadCommunity : (id == 'chats' ? _pendingRequests : 0));

    Widget screenFor(String id) {
      switch (id) {
        case 'stories':
          return const StoriesTabScreen();
        case 'announcements':
          return const AnnouncementsScreen();
        case 'community':
          return const CommunityScreen();
        case 'nearby':
          return const NearbyScreen();
        case 'settings':
          return const SettingsScreen();
        default:
          return const ChatListScreen();
      }
    }

    return PopScope(
      canPop: _current == 'chats',
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _current = 'chats');
      },
      child: Scaffold(
        body: IndexedStack(
          index: index,
          children: [for (final t in tabs) KeyedSubtree(key: ValueKey(t.id), child: screenFor(t.id))],
        ),
        // A bar with only one section would just be noise — hide it.
        bottomNavigationBar: tabs.length < 2
            ? null
            : NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (i) => setState(() => _current = tabs[i].id),
                destinations: [
                  for (final t in tabs)
                    NavigationDestination(
                      icon: Badge(isLabelVisible: badgeFor(t.id) > 0, label: Text('${badgeFor(t.id)}'), child: Icon(t.icon)),
                      selectedIcon: Badge(isLabelVisible: badgeFor(t.id) > 0, label: Text('${badgeFor(t.id)}'), child: Icon(t.selectedIcon)),
                      label: context.tr(t.label),
                    ),
                ],
              ),
      ),
    );
  }
}

class _Tab {
  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const _Tab(this.id, this.label, this.icon, this.selectedIcon);
}
