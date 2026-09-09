import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/auth_service.dart';
import '../services/chat_freeze_service.dart';
import '../services/chat_lock_service.dart';
import '../services/conversation_service.dart';
import '../services/group_service.dart';
import '../services/local_message_store.dart';
import 'chat/chat_detail_screen.dart';
import 'contacts/contacts_screen.dart';
import 'contacts/find_users_screen.dart';
import 'groups/create_group_screen.dart';
import 'groups/group_chat_screen.dart';
import 'groups/group_invites_screen.dart';
import 'settings/account_security_screen.dart';
import 'settings/edit_profile_screen.dart';
import 'settings/settings_screen.dart';

/// A row shown on the home screen — either a real ConversationSummary (has
/// at least one local message) or a placeholder for a conversation/group
/// you've opened/created but haven't sent anything in yet.
class _ChatRow {
  final String conversationId;
  final String peerUid;
  final bool isGroup;
  final String? title; // group name — null for 1:1 rows (resolved via _usernameFor instead)
  final String? avatarUrl; // group avatar — null for 1:1 rows
  final String lastText;
  final DateTime lastAt;
  final int unreadCount;
  final bool isPlaceholder;
  final bool muted;
  final bool archived;
  final bool pinned;

  _ChatRow({
    required this.conversationId,
    required this.peerUid,
    this.isGroup = false,
    this.title,
    this.avatarUrl,
    required this.lastText,
    required this.lastAt,
    required this.unreadCount,
    required this.isPlaceholder,
    this.muted = false,
    this.archived = false,
    this.pinned = false,
  });
}

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final Map<String, String> _usernameCache = {};
  final _conversationService = ConversationService();

  List<ConversationSummary> _localSummaries = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _convoDocs = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _groupDocs = [];
  bool _localLoaded = false;
  bool _convoLoaded = false;
  bool _groupsLoaded = false;

  /// Toggles the main list between normal chats and archived ones — see
  /// ConversationService/GroupService's setArchived. No separate screen:
  /// same list, same tap targets, just a different filter and a back
  /// arrow in the app bar while active.
  bool _showArchived = false;

  /// Feature: chat hiding — see ChatLockService. No visible toggle for
  /// this anywhere in the UI on purpose (unlike _showArchived, which has
  /// a normal "Archived chats" row) — the only way in is typing a
  /// configured code into the search screen (see the search IconButton
  /// below), which pops back here with a result telling us to show this
  /// view instead of pushing a whole separate screen.
  ///
  /// The common code reveals every chat hidden with it (_hiddenViewChatId
  /// stays null). A chat's own custom code reveals ONLY that one chat —
  /// _hiddenViewChatId is set to its conversationId and the rows list
  /// below is narrowed to just that.
  bool _showHiddenOnly = false;
  String? _hiddenViewChatId;
  Set<String> _hiddenIds = {}; // union of common + custom, used to filter the NORMAL view

  Future<void> _loadHiddenIds() async {
    final ids = await ChatLockService.getAllHiddenIds();
    if (!mounted) return;
    setState(() => _hiddenIds = ids);
  }

  /// Feature: mutual timed block ("Pause this chat" — see
  /// ChatFreezeService). Both sides of a paused 1:1 chat need it gone
  /// from their list, not just whoever started it, which is why this is
  /// keyed by the OTHER person's uid (not a conversationId) — the same
  /// freeze doc is visible and enforced identically from either side.
  Set<String> _frozenPeerUids = {};
  StreamSubscription? _freezeSub;
  Timer? _freezeSweepTimer;
  List<FrozenChatInfo> _activeFreezes = [];

  void _recomputeFrozenPeers() {
    final now = DateTime.now();
    final active = _activeFreezes.where((f) => f.expiresAt.isAfter(now)).map((f) => f.otherUid).toSet();
    if (!mounted) return;
    setState(() => _frozenPeerUids = active);
  }

  late final StreamSubscription _localSub;
  late final StreamSubscription _convoSub;
  late final StreamSubscription _groupsSub;

  @override
  void initState() {
    super.initState();
    _loadHiddenIds();
    _freezeSub = ChatFreezeService.instance.watchMyActiveFreezes().listen((freezes) {
      _activeFreezes = freezes;
      _recomputeFrozenPeers();
    });
    // Firestore only pushes a new snapshot when the DOCUMENT changes —
    // nothing fires just because time passed and an expiresAt is now in
    // the past, so this is what actually lets a paused chat quietly
    // reappear once its time is up, without needing anyone to touch
    // anything (the same "no server compute" client-side-timer pattern
    // main.dart already uses for disappearing messages).
    _freezeSweepTimer = Timer.periodic(const Duration(seconds: 30), (_) => _recomputeFrozenPeers());
    _localSub = LocalMessageStore.watchSummaries().listen((list) {
      if (!mounted) return;
      setState(() {
        _localSummaries = list;
        _localLoaded = true;
      });
    });

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    _convoSub = FirebaseFirestore.instance
        .collection('conversations')
        .where('participants', arrayContains: myUid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _convoDocs = snap.docs;
        _convoLoaded = true;
      });
    });

    _groupsSub = GroupService.instance.myGroupsStream().listen((snap) {
      if (!mounted) return;
      setState(() {
        _groupDocs = snap.docs;
        _groupsLoaded = true;
      });
    });

    // Show a one-time welcome / welcome-back message set by AuthService
    // right after sign-in or sign-up.
    final welcome = AuthService.pendingWelcomeMessage;
    if (welcome != null) {
      AuthService.pendingWelcomeMessage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(welcome), duration: const Duration(seconds: 4)),
        );
      });
    }
  }

  @override
  void dispose() {
    _localSub.cancel();
    _convoSub.cancel();
    _groupsSub.cancel();
    _freezeSub?.cancel();
    _freezeSweepTimer?.cancel();
    super.dispose();
  }

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  /// Muted/archived are per-person flags stored on the conversation/group
  /// doc itself (see ConversationService/GroupService), not on the local
  /// message-derived summary — so they're looked up here from whichever
  /// raw Firestore doc matches this row's id, independent of whether the
  /// row itself came from [_localSummaries] or a placeholder.
  bool _isMuted(String conversationId) {
    for (final d in _convoDocs) {
      if (d.id == conversationId) return _conversationService.isMutedByMe(d.data());
    }
    for (final d in _groupDocs) {
      if (d.id == conversationId) return GroupService.instance.isMutedByMe(d.data());
    }
    return false;
  }

  bool _isArchived(String conversationId) {
    for (final d in _convoDocs) {
      if (d.id == conversationId) return _conversationService.isArchivedByMe(d.data());
    }
    for (final d in _groupDocs) {
      if (d.id == conversationId) return GroupService.instance.isArchivedByMe(d.data());
    }
    return false;
  }

  bool _isPinned(String conversationId) {
    for (final d in _convoDocs) {
      if (d.id == conversationId) return _conversationService.isPinnedByMe(d.data());
    }
    for (final d in _groupDocs) {
      if (d.id == conversationId) return GroupService.instance.isPinnedByMe(d.data());
    }
    return false;
  }

  /// Merges real message-backed summaries with any 1:1 conversation or
  /// group you've opened/created but not messaged in yet, so a chat shows
  /// up on the home screen the moment you start it — not only after the
  /// first message is sent.
  List<_ChatRow> _mergedRows(String myUid) {
    final byConvo = <String, _ChatRow>{};
    for (final s in _localSummaries) {
      byConvo[s.conversationId] = _ChatRow(
        conversationId: s.conversationId,
        peerUid: s.peerUid,
        isGroup: s.isGroup,
        title: s.isGroup ? (s.groupName ?? 'Group') : null,
        avatarUrl: s.isGroup ? s.groupAvatarUrl : null,
        lastText: s.lastText,
        lastAt: s.lastAt,
        unreadCount: s.unreadCount,
        isPlaceholder: false,
        muted: _isMuted(s.conversationId),
        archived: _isArchived(s.conversationId),
        pinned: _isPinned(s.conversationId),
      );
    }
    for (final doc in _convoDocs) {
      if (byConvo.containsKey(doc.id)) continue;
      final participants = List<String>.from(doc.data()['participants'] ?? []);
      final peerUid = participants.firstWhere((p) => p != myUid, orElse: () => '');
      if (peerUid.isEmpty) continue;
      final createdAt = (doc.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
      byConvo[doc.id] = _ChatRow(
        conversationId: doc.id,
        peerUid: peerUid,
        lastText: 'Say hi 👋',
        lastAt: createdAt,
        unreadCount: 0,
        isPlaceholder: true,
        muted: _conversationService.isMutedByMe(doc.data()),
        archived: _conversationService.isArchivedByMe(doc.data()),
        pinned: _conversationService.isPinnedByMe(doc.data()),
      );
    }
    for (final doc in _groupDocs) {
      if (byConvo.containsKey(doc.id)) continue;
      final data = doc.data();
      final members = List<String>.from(data['members'] ?? []);
      if (!members.contains(myUid)) continue;
      final createdAt = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
      byConvo[doc.id] = _ChatRow(
        conversationId: doc.id,
        peerUid: myUid,
        isGroup: true,
        title: (data['name'] as String?) ?? 'Group',
        avatarUrl: data['avatarUrl'] as String?,
        lastText: 'Group created — say hi 👋',
        lastAt: createdAt,
        unreadCount: 0,
        isPlaceholder: true,
        muted: GroupService.instance.isMutedByMe(data),
        archived: GroupService.instance.isArchivedByMe(data),
        pinned: GroupService.instance.isPinnedByMe(data),
      );
    }
    final rows = byConvo.values.toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.lastAt.compareTo(a.lastAt);
      });
    return rows;
  }

  Future<void> _openProfile() async {
    final doc = await AuthService().currentUserProfile();
    final username = (doc.data()?['username'] as String?) ?? '';
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => EditProfileScreen(currentUsername: username)));
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'new_chat':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const FindUsersScreen()));
        break;
      case 'new_group':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
        break;
      case 'profile':
        _openProfile();
        break;
      case 'login_activity':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountSecurityScreen()));
        break;
      case 'settings':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        leading: (_showArchived || _showHiddenOnly)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _showArchived = false;
                  _showHiddenOnly = false;
                  _hiddenViewChatId = null;
                }),
              )
            : null,
        title: Text(_showHiddenOnly ? 'Hidden chats' : (_showArchived ? 'Archived chats' : 'Chats')),
        actions: (_showArchived || _showHiddenOnly)
            ? null
            : [
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: GroupService.instance.myGroupInviteRequestsStream(),
            builder: (context, snapshot) {
              final count = snapshot.data?.docs.length ?? 0;
              return IconButton(
                icon: Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count'),
                  child: const Icon(Icons.mail_outline),
                ),
                tooltip: 'Group invites',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GroupInvitesScreen())),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search people',
            onPressed: () async {
              // Feature: chat hiding. FindUsersScreen's own search field
              // doubles as the (deliberately unlabeled) unlock spot for
              // hidden chats — typing a configured code there pops it
              // back here with 'unlock_common' (reveal every common-
              // hidden chat) or 'unlock_custom:<conversationId>' (reveal
              // only that one chat) instead of running a normal user
              // search. See ChatLockService and FindUsersScreen's
              // _onChanged/_handleUnlock for the other half of this.
              final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => const FindUsersScreen()));
              await _loadHiddenIds();
              if (!mounted || result is! String) return;
              if (result == 'unlock_common') {
                setState(() {
                  _showHiddenOnly = true;
                  _hiddenViewChatId = null;
                });
              } else if (result.startsWith('unlock_custom:')) {
                setState(() {
                  _showHiddenOnly = true;
                  _hiddenViewChatId = result.substring('unlock_custom:'.length);
                });
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: _onMenuSelected,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'new_chat',
                child: ListTile(leading: Icon(Icons.chat_bubble_outline_rounded), title: Text('New chat'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'new_group',
                child: ListTile(leading: Icon(Icons.groups_rounded), title: Text('New group'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'profile',
                child: ListTile(leading: Icon(Icons.person_outline), title: Text('Profile'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'login_activity',
                child: ListTile(leading: Icon(Icons.security_outlined), title: Text('Login activity'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Settings'), contentPadding: EdgeInsets.zero),
              ),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (myUid == null || !_localLoaded || !_convoLoaded || !_groupsLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final allRows = _mergedRows(myUid);
          // Feature: mutual timed block. A frozen 1:1 chat is invisible
          // everywhere, full stop — including the hidden-chats view, if
          // it happened to also be hidden. Groups are never frozen (this
          // feature is 1:1-only — see ChatFreezeService), so isGroup rows
          // never match this regardless of peerUid contents.
          final notFrozen = allRows.where((r) => r.isGroup || !_frozenPeerUids.contains(r.peerUid)).toList();
          final archivedCount = notFrozen.where((r) => r.archived && !_hiddenIds.contains(r.conversationId)).length;
          final rows = _showHiddenOnly
              ? notFrozen
                  .where((r) => _hiddenViewChatId != null ? r.conversationId == _hiddenViewChatId : _hiddenIds.contains(r.conversationId))
                  .toList()
              : notFrozen.where((r) => !_hiddenIds.contains(r.conversationId) && r.archived == _showArchived).toList();
          if (rows.isEmpty && !(_showArchived == false && !_showHiddenOnly && archivedCount > 0)) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _showHiddenOnly
                          ? Icons.visibility_off_outlined
                          : (_showArchived ? Icons.archive_outlined : Icons.chat_bubble_outline_rounded),
                      size: 72,
                      color: scheme.primary.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _showHiddenOnly ? 'No hidden chats' : (_showArchived ? 'No archived chats' : 'No conversations yet'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (!_showArchived && !_showHiddenOnly) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Tap the button below to message a contact, or use the menu above for a new chat or group.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rows.length + (!_showArchived && !_showHiddenOnly && archivedCount > 0 ? 1 : 0),
            itemBuilder: (context, i) {
              if (!_showArchived && !_showHiddenOnly && archivedCount > 0) {
                if (i == 0) {
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.surfaceContainerHighest,
                      child: Icon(Icons.archive_outlined, color: scheme.onSurfaceVariant),
                    ),
                    title: const Text('Archived chats'),
                    trailing: Text('$archivedCount', style: TextStyle(color: scheme.onSurfaceVariant)),
                    onTap: () => setState(() => _showArchived = true),
                  );
                }
                return _chatRowTile(context, scheme, rows[i - 1]);
              }
              return _chatRowTile(context, scheme, rows[i]);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContactsScreen())),
        tooltip: 'Message a contact',
        child: const Icon(Icons.chat_rounded),
      ),
    );
  }

  /// WhatsApp-style long-press quick actions on a chat row — pin, mute,
  /// archive, and a LOCAL-ONLY delete. "Delete chat" here intentionally
  /// only clears this device's own copy (see LocalMessageStore.
  /// clearConversation) and never notifies the other side — that's
  /// "Clear chat" in ChatSettingsScreen (MessageRelayService.
  /// clearForBoth), a distinctly different, both-sides action reachable
  /// from inside the chat itself.
  void _showChatOptions(BuildContext context, ColorScheme scheme, _ChatRow row) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(row.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(row.pinned ? 'Unpin' : 'Pin to top'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (row.isGroup) {
                  GroupService.instance.setPinned(row.conversationId, !row.pinned);
                } else {
                  _conversationService.setPinned(row.conversationId, !row.pinned);
                }
              },
            ),
            ListTile(
              leading: Icon(row.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
              title: Text(row.muted ? 'Unmute' : 'Mute'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (row.isGroup) {
                  GroupService.instance.setMuted(row.conversationId, !row.muted);
                } else {
                  _conversationService.setMuted(row.conversationId, !row.muted);
                }
              },
            ),
            ListTile(
              leading: Icon(row.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(row.archived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (row.isGroup) {
                  GroupService.instance.setArchived(row.conversationId, !row.archived);
                } else {
                  _conversationService.setArchived(row.conversationId, !row.archived);
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('Delete chat', style: TextStyle(color: scheme.error)),
              subtitle: const Text('Removes messages from this device only'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Delete this chat?'),
                    content: const Text(
                      "This removes all messages from this device only — it won't notify or affect "
                      'anyone else in the chat, and new messages will still arrive normally.',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: scheme.error),
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await LocalMessageStore.clearConversation(row.conversationId);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _chatRowTile(BuildContext context, ColorScheme scheme, _ChatRow row) {
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (row.pinned) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.push_pin, size: 15, color: scheme.onSurfaceVariant)),
        if (row.muted) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.notifications_off, size: 16, color: scheme.onSurfaceVariant)),
        if (row.unreadCount > 0)
          CircleAvatar(
            radius: 11,
            backgroundColor: scheme.primary,
            child: Text('${row.unreadCount}', style: TextStyle(fontSize: 11, color: scheme.onPrimary, fontWeight: FontWeight.w700)),
          ),
      ],
    );

    if (row.isGroup) {
      return ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          backgroundImage: row.avatarUrl != null ? NetworkImage(row.avatarUrl!) : null,
          child: row.avatarUrl == null ? const Icon(Icons.groups_rounded) : null,
        ),
        title: Text(row.title ?? 'Group'),
        subtitle: row.isPlaceholder
            ? Text(row.lastText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic))
            : FutureBuilder<String>(
                future: _usernameFor(row.peerUid),
                builder: (context, nameSnap) {
                  final sender = nameSnap.data;
                  final prefix = sender != null ? '$sender: ' : '';
                  return Text('$prefix${row.lastText}', maxLines: 1, overflow: TextOverflow.ellipsis);
                },
              ),
        trailing: trailing,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: row.conversationId)))
            .then((_) => _loadHiddenIds()),
        onLongPress: () => _showChatOptions(context, scheme, row),
      );
    }

    return FutureBuilder<String>(
      future: _usernameFor(row.peerUid),
      builder: (context, nameSnap) {
        final username = nameSnap.data ?? '…';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
          ),
          title: Text(username),
          subtitle: Text(
            row.lastText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: row.isPlaceholder ? TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic) : null,
          ),
          trailing: trailing,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatDetailScreen(conversationId: row.conversationId, peerUid: row.peerUid, peerUsername: username),
            ),
          ).then((_) => _loadHiddenIds()),
          onLongPress: () => _showChatOptions(context, scheme, row),
        );
      },
    );
  }
}
