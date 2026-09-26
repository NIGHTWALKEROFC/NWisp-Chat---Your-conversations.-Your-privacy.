import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/group_service.dart';
import '../services/home_sections_service.dart';
import '../services/local_message_store.dart';
import 'announcements_screen.dart';
import 'chat_list_screen.dart';
import 'community/community_screen.dart';
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

  @override
  void initState() {
    super.initState();
    HomeSectionsService.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
    HomeSectionsService.announcementsTab.addListener(_onSettingChanged);
    HomeSectionsService.communityTab.addListener(_onSettingChanged);
    _groupsSub = GroupService.instance.myGroupsStream().listen((snap) {
      if (mounted) setState(() => _groupDocs = snap.docs);
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
    _groupsSub?.cancel();
    _summarySub?.cancel();
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

    final tabs = <_Tab>[
      const _Tab('chats', 'Chats', Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
      const _Tab('stories', 'Stories', Icons.auto_awesome_motion_outlined, Icons.auto_awesome_motion),
      if (showAnnouncements) const _Tab('announcements', 'Announcements', Icons.campaign_outlined, Icons.campaign),
      if (showCommunity) const _Tab('community', 'Community', Icons.groups_2_outlined, Icons.groups_2),
    ];
    if (!tabs.any((t) => t.id == _current)) _current = 'chats';
    final index = tabs.indexWhere((t) => t.id == _current);

    final unreadAnnouncements = _unreadWhere((d) => d['onlyAdminsCanSend'] == true && d['isCommunity'] != true);
    final unreadCommunity = _unreadWhere((d) => d['isCommunity'] == true);

    int badgeFor(String id) => id == 'announcements' ? unreadAnnouncements : (id == 'community' ? unreadCommunity : 0);

    Widget screenFor(String id) {
      switch (id) {
        case 'stories':
          return const StoriesTabScreen();
        case 'announcements':
          return const AnnouncementsScreen();
        case 'community':
          return const CommunityScreen();
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
                      label: t.label,
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
