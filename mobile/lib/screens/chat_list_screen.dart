import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/contact_service.dart';
import '../models/local_message.dart';
import '../services/app_badge_service.dart';
import '../services/app_lock_service.dart';
import '../services/note_to_self_service.dart';
import '../services/security_chat_service.dart';
import '../services/auth_service.dart';
import '../services/chat_freeze_service.dart';
import '../services/chat_lock_service.dart';
import '../services/chat_folder_service.dart';
import '../services/conversation_service.dart';
import '../services/group_service.dart';
import '../services/home_sections_service.dart';
import '../services/local_message_store.dart';
import '../services/settings_service.dart';
import '../services/signal_session_service.dart';
import '../widgets/mute_duration_sheet.dart';
import '../widgets/nwisp_ui.dart';
import '../widgets/security_chat_tile.dart';
import '../widgets/stories_strip.dart';
import '../widgets/user_avatar.dart';
import 'chat/chat_detail_screen.dart';
import 'chat/scheduled_messages_screen.dart';
import 'notes/note_to_self_screen.dart';
import 'vault/media_vault_screen.dart';
import 'chat_folders_screen.dart';
import 'contacts/contacts_screen.dart';
import 'contacts/find_users_screen.dart';
import 'global_search_screen.dart';
import 'groups/create_group_screen.dart';
import 'broadcast/broadcast_lists_screen.dart';
import 'groups/group_chat_screen.dart';
import 'groups/group_invites_screen.dart';
import 'security/chat_pin_guard.dart';
import 'settings/account_security_screen.dart';
import 'settings/edit_profile_screen.dart';
import 'bots/create_bot_screen.dart';
import 'community/create_community_screen.dart';
import 'contacts/qr_code_screen.dart';
import 'browser/in_app_browser_screen.dart';
import 'secret/secret_chat_screen.dart';
import 'settings/settings_screen.dart';
import 'starred_messages_screen.dart';
import '../services/chat_wallpaper_service.dart';
import '../services/home_background_service.dart';
import '../services/bot_service.dart';
import '../services/nickname_service.dart';
import '../widgets/nickname_dialog.dart';
import '../widgets/bot_badge.dart';
import 'bots/bot_chat_screen.dart';

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

  /// Feature: "Mark as unread" — a local reminder flag, see
  /// LocalMessageStore.setManualUnread. Only shown as a dot when there are
  /// no REAL unread messages (a real unread count always wins).
  final bool markedUnread;

  /// Feature: timed mute — when the current timed mute ends, or null for a
  /// forever-mute (or not muted at all).
  final DateTime? mutedUntil;

  /// Feature: permission-gated forwarding — the other person asked to
  /// forward messages from this chat and is waiting on my answer.
  final bool forwardRequestPending;

  /// Feature: message drafts — unsent compose-bar text left in this chat
  /// (see LocalMessageStore.watchDrafts). When non-null, the row's
  /// subtitle shows "Draft: ..." instead of the last real message, the
  /// same way WhatsApp/Telegram do — the draft always wins over lastText
  /// for display purposes, but lastText/lastAt are untouched underneath.
  final String? draftText;

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
    this.markedUnread = false,
    this.mutedUntil,
    this.forwardRequestPending = false,
    this.draftText,
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

  // ---- Feature: bots shown in the chat list (Telegram style) --------------
  List<BotInfo> _bots = [];
  bool _botOpenBusy = false;

  Future<void> _loadBots() async {
    try {
      final list = await BotService.instance.myChats();
      if (mounted) setState(() => _bots = list);
    } catch (_) {
      // Bots are optional — never break the chat list over them.
    }
  }

  // ---- Feature: search inside the chat list ---------------------------------
  final _searchCtrl = TextEditingController();
  String _query = '';

  // ---- Feature: multi-select (WhatsApp style) -------------------------------
  final Set<String> _selected = {};
  List<_ChatRow> _lastRows = [];
  bool get _selecting => _selected.isNotEmpty;

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  List<_ChatRow> get _selectedRows => _lastRows.where((r) => _selected.contains(r.conversationId)).toList();

  void _clearSelection() => setState(_selected.clear);

  Future<void> _bulkPin() async {
    final rows = _selectedRows;
    final pin = rows.any((r) => !r.pinned);
    for (final r in rows) {
      if (r.pinned == pin) continue;
      if (r.isGroup) {
        await GroupService.instance.setPinned(r.conversationId, pin);
      } else {
        await _conversationService.setPinned(r.conversationId, pin);
      }
    }
    _clearSelection();
    _snack(pin ? 'Pinned' : 'Unpinned');
  }

  Future<void> _bulkMute() async {
    final rows = _selectedRows;
    final anyUnmuted = rows.any((r) => !r.muted);
    try {
      if (!anyUnmuted) {
        for (final r in rows) {
          await _setMutedForever(r, false);
        }
        _snack('Notifications are back on');
      } else {
        final choice = await showMuteDurationSheet(context);
        if (choice == null || !mounted) return;
        for (final r in rows) {
          if (r.muted) continue;
          if (choice.isForever) {
            await _setMutedForever(r, true);
          } else {
            await _muteForDuration(r, choice.duration!);
          }
        }
        _snack('Muted ${choice.label}');
      }
      _clearSelection();
    } catch (_) {
      _snack("Couldn't change mute — check your connection and try again.");
    }
  }

  Future<void> _bulkArchive() async {
    final rows = _selectedRows;
    final archive = rows.any((r) => !r.archived);
    try {
      for (final r in rows) {
        if (r.archived == archive) continue;
        if (r.isGroup) {
          await GroupService.instance.setArchived(r.conversationId, archive);
        } else {
          await _conversationService.setArchived(r.conversationId, archive);
        }
      }
      _clearSelection();
      _snack(archive ? 'Chats archived' : 'Chats moved back');
    } catch (_) {
      _snack("Couldn't update these chats — check your connection and try again.");
    }
  }

  Future<void> _bulkDelete() async {
    final rows = _selectedRows;
    if (rows.isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(rows.length == 1 ? 'Delete this chat?' : 'Delete ${rows.length} chats?'),
        content: const Text(
          "This removes the chats and their messages from this device only — it won't notify or affect anyone else. "
          'A chat comes back when either of you sends a new message.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final r in rows) {
      await LocalMessageStore.clearConversation(r.conversationId);
      await LocalMessageStore.markChatDeletedLocally(r.conversationId);
    }
    _clearSelection();
  }

  Future<void> _bulkMarkUnread() async {
    final rows = _selectedRows.where((r) => !r.isPlaceholder && r.unreadCount == 0).toList();
    final markUnread = rows.any((r) => !r.markedUnread);
    for (final r in rows) {
      await LocalMessageStore.setManualUnread(r.conversationId, markUnread);
    }
    _clearSelection();
  }

  AppBar _selectionAppBar(ColorScheme scheme) {
    final rows = _selectedRows;
    final allPinned = rows.isNotEmpty && rows.every((r) => r.pinned);
    final allMuted = rows.isNotEmpty && rows.every((r) => r.muted);
    final allArchived = rows.isNotEmpty && rows.every((r) => r.archived);
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          icon: Icon(allPinned ? Icons.push_pin : Icons.push_pin_outlined),
          tooltip: allPinned ? 'Unpin' : 'Pin',
          onPressed: _bulkPin,
        ),
        IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: _bulkDelete),
        IconButton(
          icon: Icon(allMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
          tooltip: allMuted ? 'Unmute' : 'Mute',
          onPressed: _bulkMute,
        ),
        IconButton(
          icon: Icon(allArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
          tooltip: allArchived ? 'Unarchive' : 'Archive',
          onPressed: _bulkArchive,
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'nick') {
              final r = _selectedRows.first;
              showNicknameDialog(context, uid: r.peerUid, realName: _usernameCache[r.peerUid] ?? 'this person').then((_) => _clearSelection());
              return;
            }
            if (v == 'all') {
              setState(() => _selected.addAll(_lastRows.where((r) => !NoteToSelfService.isNotes(r.conversationId)).map((r) => r.conversationId)));
            } else if (v == 'unread') {
              _bulkMarkUnread();
            }
          },
          itemBuilder: (_) => [
            if (_selected.length == 1 && !_selectedRows.first.isGroup && !NoteToSelfService.isNotes(_selectedRows.first.conversationId))
              const PopupMenuItem(value: 'nick', child: Text('Set nickname')),
            const PopupMenuItem(value: 'all', child: Text('Select all')),
            const PopupMenuItem(value: 'unread', child: Text('Mark as read / unread')),
          ],
        ),
      ],
    );
  }
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

  // Feature: "Mark as unread" — see LocalMessageStore.watchManualUnread.
  Set<String> _manualUnread = {};
  StreamSubscription<Set<String>>? _manualUnreadSub;

  // Bug fix: "Delete chat" — conversationIds removed from THIS device's
  // home screen (see LocalMessageStore.watchDeletedChats /
  // markChatDeletedLocally). Filtered out of _mergedRows below entirely.
  Set<String> _deletedChats = {};
  StreamSubscription<Set<String>>? _deletedChatsSub;

  // Feature: message drafts — conversationId -> unsent compose-bar text
  // (see LocalMessageStore.watchDrafts). Shown as "Draft: ..." on the row.
  Map<String, String> _drafts = {};
  StreamSubscription<Map<String, String>>? _draftsSub;

  late final StreamSubscription _localSub;
  late final StreamSubscription _convoSub;
  late final StreamSubscription _groupsSub;
  // Feature: chat folders/categories.
  List<ChatFolder> _folders = [];
  String? _selectedFolderId;
  late final StreamSubscription<List<ChatFolder>> _foldersSub;
  // Feature: separate groups and chats on the home screen. Off by
  // default — see SettingsService.getSeparateGroupsAndChats.
  bool _separateGroupsAndChats = false;
  static const _archivedHeaderMarker = '__archived_header_marker__';
  static const _securityRowMarker = '__security_row_marker__';
  static const _openBotMarker = '__open_bot_marker__';

  /// Feature: "NWisp Chat Notifications" — the read-only account-alerts chat.
  /// [_securityNotices] is its newest-first message list; the row only exists
  /// once that list has something in it (see _securityRowFor).
  List<SecurityNotice> _securityNotices = const [];
  StreamSubscription<List<SecurityNotice>>? _securitySub;

  // Feature: anti-tampering / MITM re-verification prompts, shown "on
  // entering the app" (i.e. here, on the chat list) rather than only
  // inside a specific chat. Recomputed each time the conversation list
  // changes, throttled so a burst of Firestore snapshots can't trigger a
  // flood of per-peer checks.
  final Set<String> _peersWithChangedIdentity = {};
  DateTime? _lastIdentityCheck;

  Future<void> _checkIdentityChanges(String myUid) async {
    final now = DateTime.now();
    if (_lastIdentityCheck != null && now.difference(_lastIdentityCheck!) < const Duration(seconds: 60)) return;
    _lastIdentityCheck = now;
    final peerUids = <String>{};
    for (final doc in _convoDocs) {
      final participants = List<String>.from(doc.data()['participants'] ?? []);
      final peer = participants.firstWhere((p) => p != myUid, orElse: () => '');
      if (peer.isNotEmpty) peerUids.add(peer);
    }
    final changed = <String>{};
    for (final uid in peerUids) {
      if (await SignalSessionService.instance.hasUnverifiedIdentityChange(uid)) changed.add(uid);
    }
    if (mounted) setState(() => _peersWithChangedIdentity..clear()..addAll(changed));
  }

  // Feature: home sections. Re-filter the list the moment the Announcements
  // switch in Settings > Chats is flipped.
  void _onSectionSettingChanged() {
    if (mounted) setState(() {});
  }

  /// Feature: home sections. Community groups live in the Community tab and
  /// announcement-only groups in the Announcements tab while those sections
  /// are switched on — they are kept out of Chats. Switch a section off and
  /// its groups simply appear here again, like any other group.
  bool _belongsToOtherSection(_ChatRow r) {
    if (!r.isGroup) return false;
    for (final d in _groupDocs) {
      if (d.id != r.conversationId) continue;
      final data = d.data();
      if (data['isCommunity'] == true && HomeSectionsService.communityTab.value) return true;
      if (data['onlyAdminsCanSend'] == true && HomeSectionsService.announcementsTab.value) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HomeSectionsService.announcementsTab.addListener(_onSectionSettingChanged);
    HomeSectionsService.communityTab.addListener(_onSectionSettingChanged);
    HomeSectionsService.storiesOnHome.addListener(_onSectionSettingChanged);
    NicknameService.instance.load();
    NicknameService.instance.changes.addListener(_onSectionSettingChanged);
    _loadHiddenIds();
    _loadBots();
    _startSecurityWatch();
    _manualUnreadSub = LocalMessageStore.watchManualUnread().listen((ids) {
      if (mounted) setState(() => _manualUnread = ids);
    });
    _deletedChatsSub = LocalMessageStore.watchDeletedChats().listen((ids) {
      if (mounted) setState(() => _deletedChats = ids);
    });
    _draftsSub = LocalMessageStore.watchDrafts().listen((drafts) {
      if (mounted) setState(() => _drafts = drafts);
    });
    _foldersSub = ChatFolderService.watchFolders().listen((f) {
      if (mounted) setState(() => _folders = f);
    });
    SettingsService.getSeparateGroupsAndChats().then((v) {
      if (mounted) setState(() => _separateGroupsAndChats = v);
    });
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
      if (myUid != null) _checkIdentityChanges(myUid);
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
    HomeSectionsService.announcementsTab.removeListener(_onSectionSettingChanged);
    HomeSectionsService.communityTab.removeListener(_onSectionSettingChanged);
    HomeSectionsService.storiesOnHome.removeListener(_onSectionSettingChanged);
    NicknameService.instance.changes.removeListener(_onSectionSettingChanged);
    SecurityChatService.instance.readTick.removeListener(_onSecurityRead);
    _securitySub?.cancel();
    _localSub.cancel();
    _convoSub.cancel();
    _groupsSub.cancel();
    _foldersSub.cancel();
    _manualUnreadSub?.cancel();
    _deletedChatsSub?.cancel();
    _draftsSub?.cancel();
    _freezeSub?.cancel();
    _freezeSweepTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Feature: anti-tampering / MITM re-verification prompts, entry-level
  /// version. Doesn't try to name every affected contact in the limited
  /// space here — just flags that it happened and points at where to
  /// actually deal with it, since the real per-contact banner (and the
  /// Verify/Trust actions) already live inside ChatDetailScreen itself.
  /// Feature: chat folders/categories. A horizontal chip row — "All"
  /// plus one chip per folder — that filters the chat list below.
  /// Managed (create/rename/delete/assign chats) from the "Chat
  /// folders" entry in the overflow menu; this row only ever shows once
  /// at least one folder exists, so nobody who's never used folders
  /// sees any change to the home screen at all.
  Widget _buildFolderChipsRow(ColorScheme scheme) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: const Text('All'),
              selected: _selectedFolderId == null,
              onSelected: (_) => setState(() => _selectedFolderId = null),
            ),
          ),
          for (final f in _folders)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(f.name),
                selected: _selectedFolderId == f.id,
                onSelected: (_) => setState(() => _selectedFolderId = _selectedFolderId == f.id ? null : f.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIdentityChangeBanner(ColorScheme scheme, String? myUid) {
    final count = _peersWithChangedIdentity.length;
    return Material(
      color: scheme.errorContainer,
      child: InkWell(
        onTap: () async {
          final uid = _peersWithChangedIdentity.first;
          final username = await _usernameFor(uid);
          if (!mounted) return;
          final conversationId = myUid == null ? uid : _conversationService.conversationIdFor(myUid, uid);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ChatDetailScreen(conversationId: conversationId, peerUid: uid, peerUsername: username)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.gpp_maybe_outlined, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  count == 1
                      ? "A contact's security code changed — open their chat to review"
                      : "$count contacts' security codes changed — open each chat to review",
                  style: TextStyle(fontSize: 12.5, color: scheme.onErrorContainer),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }

  /// What this screen shows for a person: my private nickname for them if I
  /// set one (Feature: nicknames — see NicknameService), otherwise their
  /// username.
  Future<String> _usernameFor(String uid) async {
    await NicknameService.instance.load();
    return NicknameService.instance.display(uid, await _realUsernameFor(uid));
  }

  Future<String> _realUsernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final stored = ((doc.data()?['username'] as String?) ?? '').trim();
    final name = stored.isEmpty ? 'Unknown' : stored;
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

  /// When my timed mute on this chat ends — null if it isn't muted, or is
  /// muted forever. Only returns a time still in the future.
  DateTime? _muteExpiry(String conversationId) {
    DateTime? until;
    for (final d in _convoDocs) {
      if (d.id == conversationId) until = _conversationService.muteExpiryFor(d.data());
    }
    for (final d in _groupDocs) {
      if (d.id == conversationId) until = GroupService.instance.muteExpiryFor(d.data());
    }
    if (until != null && until.isAfter(DateTime.now())) return until;
    return null;
  }

  bool _hasIncomingForwardRequest(String conversationId) {
    for (final d in _convoDocs) {
      if (d.id == conversationId) return _conversationService.hasIncomingForwardingRequest(d.data());
    }
    return false;
  }

  /// Merges real message-backed summaries with any 1:1 conversation or
  /// group you've opened/created but not messaged in yet, so a chat shows
  /// up on the home screen the moment you start it — not only after the
  /// first message is sent.
  Future<void> _startSecurityWatch() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await SecurityChatService.instance.load();
    if (!mounted) return;
    SecurityChatService.instance.readTick.addListener(_onSecurityRead);
    _securitySub = SecurityChatService.instance.notices(uid).listen((list) {
      if (mounted) setState(() => _securityNotices = list);
    });
  }

  // Opening the notifications chat clears its unread badge right away.
  void _onSecurityRead() {
    if (mounted) setState(() {});
  }

  /// Puts the notifications row into an already-sorted list of chats, at the
  /// place its newest notice belongs by time — after any pinned chats, before
  /// the first chat that's older than it. So a new message in a normal chat
  /// pushes it up above this row, exactly like it would for any other chat.
  /// Returns the list untouched when there are no notices yet.
  List<Object> _withSecurityRow(List<_ChatRow> sorted) {
    if (_securityNotices.isEmpty) return List<Object>.of(sorted);
    final at = _securityNotices.first.time ?? DateTime.now();
    var index = sorted.length;
    for (var i = 0; i < sorted.length; i++) {
      if (!sorted[i].pinned && sorted[i].lastAt.isBefore(at)) {
        index = i;
        break;
      }
    }
    final out = List<Object>.of(sorted);
    out.insert(index, _securityRowMarker);
    return out;
  }

  List<_ChatRow> _mergedRows(String myUid) {
    final byConvo = <String, _ChatRow>{};
    for (final s in _localSummaries) {
      // Bug fix: "Delete chat" — skip a conversation the person removed
      // from their own home screen. It comes back on its own the moment
      // a new message exists (LocalMessageStore.insert clears the flag),
      // so this only ever hides genuinely-empty-since-deletion chats.
      if (_deletedChats.contains(s.conversationId)) continue;
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
        markedUnread: _manualUnread.contains(s.conversationId),
        mutedUntil: _muteExpiry(s.conversationId),
        forwardRequestPending: !s.isGroup && _hasIncomingForwardRequest(s.conversationId),
        draftText: _drafts[s.conversationId],
      );
    }
    for (final doc in _convoDocs) {
      if (byConvo.containsKey(doc.id)) continue;
      if (_deletedChats.contains(doc.id)) continue; // see comment above
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
        markedUnread: _manualUnread.contains(doc.id),
        mutedUntil: _muteExpiry(doc.id),
        forwardRequestPending: _conversationService.hasIncomingForwardingRequest(doc.data()),
        draftText: _drafts[doc.id],
      );
    }
    for (final doc in _groupDocs) {
      if (byConvo.containsKey(doc.id)) continue;
      if (_deletedChats.contains(doc.id)) continue; // see comment above
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
        markedUnread: _manualUnread.contains(doc.id),
        mutedUntil: _muteExpiry(doc.id),
        draftText: _drafts[doc.id],
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

  /// Feature: secret chat from the home screen — asks which chat to start it
  /// with, then shows the rules and sends the request.
  Future<void> _pickSecretChat() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;
    final peers = _mergedRows(myUid)
        .where((r) => !r.isGroup && r.peerUid.isNotEmpty && r.peerUid != myUid)
        .map((r) => r.peerUid)
        .toSet()
        .toList();
    if (peers.isEmpty) {
      _snack('Start a normal chat with someone first, then you can open a secret chat with them.');
      return;
    }
    final names = <String, String>{for (final u in peers) u: await _usernameFor(u)};
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Secret chat with…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final u in peers)
                      ListTile(
                        leading: UserAvatar(uid: u, name: names[u] ?? '', radius: 22),
                        title: Text(names[u] ?? 'Unknown'),
                        trailing: const Icon(Icons.lock_clock_outlined),
                        onTap: () => Navigator.pop(ctx, u),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) {
      await startSecretChatWith(context, peerUid: picked, peerName: names[picked] ?? 'Unknown');
    }
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'new_chat':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const FindUsersScreen()));
        break;
      case 'new_group':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
        break;
      case 'broadcast_lists':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const BroadcastListsScreen()));
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
      case 'new_community':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateCommunityScreen()));
        break;
      case 'contacts':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ContactsScreen()));
        break;
      case 'qr':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const QrCodeScreen()));
        break;
      case 'new_bot':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateBotScreen()));
        break;
      case 'secret_chat':
        _pickSecretChat();
        break;
      case 'private_browser':
        openInAppBrowser(context);
        break;
      case 'global_search':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalSearchScreen()));
        break;
      case 'starred':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const StarredMessagesScreen()));
        break;
      case 'folders':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatFoldersScreen()));
        break;
      case 'note_to_self':
        // Feature: Note to self — a private, local-only notepad.
        Navigator.push(context, MaterialPageRoute(builder: (_) => const NoteToSelfScreen()));
        break;
      case 'scheduled':
        // Feature: send later — every message waiting to be sent.
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ScheduledMessagesScreen()));
        break;
      case 'media_vault':
        // Feature: locked media vault (its own PIN — see MediaVaultScreen).
        Navigator.push(
          context,
          MaterialPageRoute(settings: const RouteSettings(name: '/vault'), builder: (_) => const MediaVaultScreen()),
        );
        break;
    }
  }

  /// Feature: "Lock now". Locks the app instantly and closes every open
  /// screen (see the lock gate in auth_gate.dart). Only meaningful if App
  /// lock is on — otherwise there's no PIN to lock behind, so say so.
  Future<void> _lockNow() async {
    if (!await AppLockService.isEnabled()) {
      _snack('Turn on App lock in Settings > Security to use Lock now.');
      return;
    }
    AppLockService.requestLockNow();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    // Feature: home screen background — wraps the whole Scaffold so the
    // chosen background shows through behind everything (app bar included),
    // the same way a chat's own wallpaper shows through behind its messages.
    return Stack(
      children: [
        const Positioned.fill(child: _HomeBackgroundView()),
        Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _selecting ? _selectionAppBar(scheme) : AppBar(
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
        title: (_showHiddenOnly || _showArchived)
            ? Text(_showHiddenOnly ? 'Hidden chats' : 'Archived chats')
            : const NwispWordmark(fontSize: 22, alignment: MainAxisAlignment.start),
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
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Lock now',
            onPressed: _lockNow,
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
              PopupMenuItem(
                value: 'broadcast_lists',
                child: ListTile(leading: Icon(Icons.campaign_outlined), title: Text('New broadcast'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'new_community',
                child: ListTile(leading: Icon(Icons.groups_2_outlined), title: Text('New community'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'secret_chat',
                child: ListTile(leading: Icon(Icons.lock_clock_outlined), title: Text('Secret chat'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'new_bot',
                child: ListTile(leading: Icon(Icons.smart_toy_outlined), title: Text('New bot'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'contacts',
                child: ListTile(leading: Icon(Icons.people_alt_outlined), title: Text('Contacts & requests'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'qr',
                child: ListTile(leading: Icon(Icons.qr_code_scanner_rounded), title: Text('Scan / show QR'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'note_to_self',
                child: ListTile(leading: Icon(Icons.edit_note), title: Text('Note to self'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'folders',
                child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Chat folders'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'global_search',
                child: ListTile(leading: Icon(Icons.manage_search_outlined), title: Text('Search all chats'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'starred',
                child: ListTile(leading: Icon(Icons.star_border), title: Text('Starred messages'), contentPadding: EdgeInsets.zero),
              ),
              PopupMenuItem(
                value: 'private_browser',
                child: ListTile(leading: Icon(Icons.shield_moon_outlined), title: Text('Private browser'), contentPadding: EdgeInsets.zero),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_peersWithChangedIdentity.isNotEmpty) _buildIdentityChangeBanner(scheme, myUid),
          // Stories row from the new design — normal chat view only.
          if (!_showHiddenOnly && !_showArchived && HomeSectionsService.storiesOnHome.value) const StoriesStrip(),
          if (!_showHiddenOnly && !_showArchived && !_selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) {
                  setState(() => _query = v.trim().toLowerCase());
                  // Make sure names are known so people can be found by name.
                  for (final r in _lastRows) {
                    if (!r.isGroup) _usernameFor(r.peerUid).then((_) {
                      if (mounted && _query.isNotEmpty) setState(() {});
                    });
                  }
                },
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search chats, people and bots',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _searchCtrl.clear();
                            _query = '';
                          }),
                        ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
              ),
            ),
          if (_folders.isNotEmpty && !_showHiddenOnly && !_showArchived) _buildFolderChipsRow(scheme),
          Expanded(
            child: Builder(
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
          // The app-icon badge counts EVERY section's unread messages…
          _updateBadge(notFrozen);
          // …but this list only shows what belongs in Chats.
          final visibleRows = notFrozen.where((r) => !_belongsToOtherSection(r)).toList();
          final archivedCount = visibleRows.where((r) => r.archived && !_hiddenIds.contains(r.conversationId)).length;
          final unfiltered = _showHiddenOnly
              ? visibleRows
                  .where((r) => _hiddenViewChatId != null ? r.conversationId == _hiddenViewChatId : _hiddenIds.contains(r.conversationId))
                  .toList()
              : visibleRows.where((r) => !_hiddenIds.contains(r.conversationId) && r.archived == _showArchived).toList();
          // Feature: chat folders/categories. Applied only in the normal
          // (not hidden, not archived) view — a folder is a filter over
          // the everyday chat list, not something that also needs to
          // apply while browsing hidden or archived chats.
          final selectedFolder = _selectedFolderId == null
              ? null
              : _folders.cast<ChatFolder?>().firstWhere((f) => f!.id == _selectedFolderId, orElse: () => null);
          var rows = (selectedFolder != null && !_showHiddenOnly && !_showArchived)
              ? unfiltered.where((r) => selectedFolder.conversationIds.contains(r.conversationId)).toList()
              : unfiltered;
          // Feature: search box above the list.
          final searching = _query.isNotEmpty && !_showHiddenOnly && !_showArchived;
          if (searching) {
            rows = rows.where((r) {
              final real = r.isGroup ? (r.title ?? '') : (_usernameCache[r.peerUid] ?? '');
              final nick = r.isGroup ? '' : (NicknameService.instance.nicknameFor(r.peerUid) ?? '');
              return real.toLowerCase().contains(_query) || nick.toLowerCase().contains(_query) || r.lastText.toLowerCase().contains(_query);
            }).toList();
          }
          _lastRows = rows;
          final bots = (_showHiddenOnly || _showArchived || selectedFolder != null)
              ? <BotInfo>[]
              : _bots.where((b) => !searching || b.name.toLowerCase().contains(_query) || b.username.contains(_query)).toList();
          final showOpenBot = searching && _query.replaceFirst('@', '').endsWith('_bot') && !_bots.any((b) => b.username == _query.replaceFirst('@', ''));
          // The notifications row only lives in the normal, unfiltered view.
          final showSecurityRow = _securityNotices.isNotEmpty && !_showHiddenOnly && !_showArchived && selectedFolder == null;
          if (rows.isEmpty && bots.isEmpty && !showOpenBot && !showSecurityRow && !(_showArchived == false && !_showHiddenOnly && archivedCount > 0)) {
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
                      _showHiddenOnly ? 'No hidden chats' : (_showArchived ? 'No archived chats' : (selectedFolder != null ? 'No chats in "${selectedFolder.name}" yet' : 'No conversations yet')),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (!_showArchived && !_showHiddenOnly && selectedFolder == null) ...[
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
          // Feature: separate groups and chats on the home screen.
          // Builds a flat list of items — either a _ChatRow, or a plain
          // String used as a section-header marker — so the existing
          // "archived chats" summary tile above can slot in at the top
          // exactly like before, whether or not sectioning is on.
          final showArchivedHeader = !_showArchived && !_showHiddenOnly && archivedCount > 0;
          final List<Object> items = [];
          if (showArchivedHeader && !searching) items.add(_archivedHeaderMarker);
          if (showOpenBot) items.add(_openBotMarker);
          items.addAll(bots);
          if (_separateGroupsAndChats && !_showHiddenOnly && !_showArchived) {
            final direct = rows.where((r) => !r.isGroup).toList();
            final groups = rows.where((r) => r.isGroup).toList();
            final directItems = showSecurityRow ? _withSecurityRow(direct) : List<Object>.of(direct);
            if (directItems.isNotEmpty) {
              items.add('Direct messages');
              items.addAll(directItems);
            }
            if (groups.isNotEmpty) {
              items.add('Groups');
              items.addAll(groups);
            }
          } else {
            items.addAll(showSecurityRow ? _withSecurityRow(rows) : rows);
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item == _archivedHeaderMarker) {
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
              if (item == _openBotMarker) {
                final u = _query.replaceFirst('@', '');
                return ListTile(
                  leading: CircleAvatar(backgroundColor: scheme.primaryContainer, child: Icon(Icons.smart_toy_outlined, color: scheme.onPrimaryContainer)),
                  title: Text('Open @$u'),
                  subtitle: const Text('Look for this bot'),
                  trailing: _botOpenBusy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.chevron_right),
                  onTap: () => _openBotByName(u),
                );
              }
              if (item is BotInfo) return _botTile(context, scheme, item);
              if (item == _securityRowMarker) {
                return SecurityChatTile(
                  latest: _securityNotices.first,
                  unread: SecurityChatService.instance.unreadCount(_securityNotices),
                );
              }
              if (item is String) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(item, style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                );
              }
              return _chatRowTile(context, scheme, item as _ChatRow);
            },
          );
        },
            ),
          ),
        ],
      ),
      floatingActionButton: StreamBuilder<int>(
        stream: ContactService().pendingRequestCountStream(),
        builder: (context, snap) {
          final n = snap.data ?? 0;
          return Badge(
            isLabelVisible: n > 0,
            label: Text(n > 99 ? '99+' : '$n'),
            offset: const Offset(-4, 2),
            child: FloatingActionButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContactsScreen())),
              tooltip: n > 0 ? '$n new contact request${n == 1 ? '' : 's'}' : 'Message a contact',
              child: const Icon(Icons.chat_rounded),
            ),
          );
        },
      ),
    ),
      ],
    );
  }

  // ---- Feature: unread badge on the app icon -----------------------------

  /// Works out the number for the app-icon badge and hands it to
  /// AppBadgeService (which skips the call if nothing changed).
  ///
  /// What counts: real unread messages, plus 1 for each chat manually
  /// "marked as unread". What NEVER counts: hidden chats (a number on the
  /// home screen would give away that a hidden chat exists), muted chats,
  /// archived chats, and paused chats.
  void _updateBadge(List<_ChatRow> rows) {
    var total = 0;
    for (final r in rows) {
      if (_hiddenIds.contains(r.conversationId) || r.archived || r.muted) continue;
      total += r.unreadCount > 0 ? r.unreadCount : (r.markedUnread ? 1 : 0);
    }
    // After the frame, never during build — updating the launcher isn't
    // part of drawing this screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => AppBadgeService.instance.update(total));
  }

  // ---- Feature: swipe actions (right = mute, left = archive) -------------

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message), action: action, duration: const Duration(seconds: 4)));
  }

  String _formatUntil(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour < 12 ? 'AM' : 'PM';
    final now = DateTime.now();
    final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final time = '$hour12:$minute $suffix';
    return sameDay ? 'today $time' : '${months[dt.month - 1]} ${dt.day}, $time';
  }

  Future<void> _setMutedForever(_ChatRow row, bool muted) {
    return row.isGroup
        ? GroupService.instance.setMuted(row.conversationId, muted)
        : _conversationService.setMuted(row.conversationId, muted);
  }

  Future<void> _muteForDuration(_ChatRow row, Duration d) {
    return row.isGroup
        ? GroupService.instance.muteFor(row.conversationId, d)
        : _conversationService.muteFor(row.conversationId, d);
  }

  /// Shared by the swipe-right gesture and the long-press "Mute" item.
  /// Already muted -> unmute straight away. Otherwise ask for how long
  /// (1 hour / 8 hours / 24 hours / 1 week / Custom… / Always).
  Future<void> _muteOrUnmute(_ChatRow row) async {
    try {
      if (row.muted) {
        await _setMutedForever(row, false);
        _snack('Notifications are back on');
        return;
      }
      final choice = await showMuteDurationSheet(context);
      if (choice == null || !mounted) return;
      if (choice.isForever) {
        await _setMutedForever(row, true);
      } else {
        await _muteForDuration(row, choice.duration!);
      }
      _snack(
        'Muted ${choice.label}',
        action: SnackBarAction(label: 'UNDO', onPressed: () => _setMutedForever(row, false)),
      );
    } catch (e) {
      _snack("Couldn't change mute — check your connection and try again.");
    }
  }

  /// Shared by the swipe-left gesture and the long-press "Archive" item.
  Future<void> _toggleArchive(_ChatRow row) async {
    final archive = !row.archived;
    Future<void> applyArchive(bool value) => row.isGroup
        ? GroupService.instance.setArchived(row.conversationId, value)
        : _conversationService.setArchived(row.conversationId, value);
    try {
      await applyArchive(archive);
      _snack(
        archive ? 'Chat archived' : 'Chat moved back to your chats',
        action: SnackBarAction(label: 'UNDO', onPressed: () => applyArchive(!archive)),
      );
    } catch (e) {
      _snack("Couldn't update this chat — check your connection and try again.");
    }
  }

  Widget _swipeBackground(
    ColorScheme scheme, {
    required Alignment alignment,
    required Color color,
    required Color onColor,
    required IconData icon,
    required String label,
  }) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onColor),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: onColor, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Wraps a chat row so it can be swiped: RIGHT = mute/unmute (with a
  /// choice of how long), LEFT = archive/unarchive. The row itself never
  /// actually leaves the list on swipe — `confirmDismiss` always returns
  /// false so it springs back, and the live Firestore streams move it
  /// between the normal and archived views on their own.
  Widget _withSwipeActions(ColorScheme scheme, _ChatRow row, Widget tile) {
    return Dismissible(
      key: ValueKey('swipe_${row.conversationId}'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          _muteOrUnmute(row);
        } else {
          _toggleArchive(row);
        }
        return false;
      },
      background: _swipeBackground(
        scheme,
        alignment: Alignment.centerLeft,
        color: scheme.secondaryContainer,
        onColor: scheme.onSecondaryContainer,
        icon: row.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
        label: row.muted ? 'Unmute' : 'Mute',
      ),
      secondaryBackground: _swipeBackground(
        scheme,
        alignment: Alignment.centerRight,
        color: scheme.primary,
        onColor: scheme.onPrimary,
        icon: row.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
        label: row.archived ? 'Unarchive' : 'Archive',
      ),
      child: tile,
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
            // Feature: "Mark as unread". Only offered when there are no REAL
            // unread messages (a chat with real unread messages is already
            // unread) — and when it's already marked, the same slot turns
            // into "Mark as read".
            if (!row.isPlaceholder && row.unreadCount == 0)
              ListTile(
                leading: Icon(row.markedUnread ? Icons.mark_chat_read_outlined : Icons.mark_chat_unread_outlined),
                title: Text(row.markedUnread ? 'Mark as read' : 'Mark as unread'),
                subtitle: row.markedUnread ? null : const Text('A private reminder to come back to this chat'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  LocalMessageStore.setManualUnread(row.conversationId, !row.markedUnread);
                },
              ),
            ListTile(
              leading: Icon(row.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
              title: Text(row.muted ? 'Unmute' : 'Mute…'),
              subtitle: row.muted
                  ? Text(row.mutedUntil != null ? 'Muted until ${_formatUntil(row.mutedUntil!)}' : 'Muted until you turn it back on')
                  : null,
              onTap: () {
                Navigator.pop(sheetContext);
                _muteOrUnmute(row);
              },
            ),
            ListTile(
              leading: Icon(row.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(row.archived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.pop(sheetContext);
                _toggleArchive(row);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('Delete chat', style: TextStyle(color: scheme.error)),
              subtitle: const Text('Removes this chat from your list — new messages bring it back'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Delete this chat?'),
                    content: const Text(
                      "This removes the chat and its messages from this device only — it won't notify or "
                      "affect anyone else in the chat. It will reappear here the next time either of you "
                      'sends a message.',
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
                  // Bug fix: clearing messages alone left the chat's row
                  // sitting on the home screen (it just reappeared empty) —
                  // markChatDeletedLocally is what actually removes the row
                  // itself, WhatsApp-style, until new activity brings it back.
                  await LocalMessageStore.clearConversation(row.conversationId);
                  await LocalMessageStore.markChatDeletedLocally(row.conversationId);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Feature: message drafts — "Draft: ..." styled like WhatsApp (the
  /// "Draft" label in the error/accent color, the text itself normal),
  /// shown instead of the last real message whenever one exists.
  Widget _draftSubtitle(ColorScheme scheme, String draftText) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Draft: ', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
          TextSpan(text: draftText.replaceAll('\n', ' ')),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Future<void> _openBotByName(String u) async {
    setState(() => _botOpenBusy = true);
    try {
      final r = await BotService.instance.getBot(u);
      if (!mounted) return;
      if (r.bot == null) {
        _snack(r.reason == 'private' ? "@$u exists but isn't open to everyone yet." : 'No bot called @$u.');
      } else {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => BotChatScreen(username: u)));
        _loadBots();
      }
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _botOpenBusy = false);
    }
  }

  Widget _botTile(BuildContext context, ColorScheme scheme, BotInfo b) {
    return ListTile(
      leading: BotAvatar(photoData: b.photoData, name: b.name),
      title: Row(children: [
        Flexible(child: Text(b.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
        const SizedBox(width: 6),
        const BotBadge(),
      ]),
      subtitle: Text(b.description.isNotEmpty ? b.description : '@${b.username}', maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => BotChatScreen(username: b.username)));
        _loadBots();
      },
    );
  }

  Widget _selectBadge(ColorScheme scheme, _ChatRow row, Widget avatar) {
    if (!_selected.contains(row.conversationId)) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -3,
          bottom: -3,
          child: CircleAvatar(radius: 9, backgroundColor: scheme.primary, child: Icon(Icons.check, size: 13, color: scheme.onPrimary)),
        ),
      ],
    );
  }

  Widget _chatRowTile(BuildContext context, ColorScheme scheme, _ChatRow row) {
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Feature: permission-gated forwarding — the other person is
        // waiting for an answer inside this chat.
        if (row.forwardRequestPending)
          Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.forward_to_inbox_outlined, size: 16, color: scheme.primary)),
        if (row.pinned) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.push_pin, size: 15, color: scheme.onSurfaceVariant)),
        // A timed mute shows a "paused" bell (it comes back on its own); a
        // forever-mute keeps the plain crossed-out bell.
        if (row.muted)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(row.mutedUntil != null ? Icons.notifications_paused_outlined : Icons.notifications_off, size: 16, color: scheme.onSurfaceVariant),
          ),
        if (row.unreadCount > 0)
          CircleAvatar(
            radius: 11,
            backgroundColor: scheme.primary,
            child: Text('${row.unreadCount}', style: TextStyle(fontSize: 11, color: scheme.onPrimary, fontWeight: FontWeight.w700)),
          )
        else if (row.markedUnread)
          // Feature: "Mark as unread" — a plain dot, no number, because
          // there's nothing actually new to count.
          CircleAvatar(radius: 6, backgroundColor: scheme.primary),
      ],
    );
    final emphasize = row.unreadCount > 0 || row.markedUnread;

    // Feature: Note to self. Its "peer" is you, so it must NOT go through the
    // normal 1:1 path (which would look up a username, open a chat screen and
    // offer archive/mute swipes that only make sense for a real chat).
    if (NoteToSelfService.isNotes(row.conversationId)) {
      return ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.edit_note, color: scheme.onPrimaryContainer),
        ),
        title: const Text('Note to self'),
        subtitle: Text(row.lastText, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NoteToSelfScreen())),
      );
    }

    if (row.isGroup) {
      return _withSwipeActions(scheme, row, ListTile(
        selected: _selected.contains(row.conversationId),
        selectedTileColor: scheme.primary.withValues(alpha: 0.14),
        leading: _selectBadge(scheme, row, CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          backgroundImage: row.avatarUrl != null ? NetworkImage(row.avatarUrl!) : null,
          child: row.avatarUrl == null ? const Icon(Icons.groups_rounded) : null,
        )),
        title: Text(row.title ?? 'Group', style: emphasize ? const TextStyle(fontWeight: FontWeight.w700) : null),
        subtitle: row.draftText != null
            ? _draftSubtitle(scheme, row.draftText!)
            : row.isPlaceholder
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
        onTap: () async {
          if (_selecting) {
            _toggleSelect(row.conversationId);
            return;
          }
          if (!await requireChatPinIfLocked(context, row.conversationId)) return;
          if (!context.mounted) return;
          await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: row.conversationId)));
          await _loadHiddenIds();
        },
        onLongPress: () => _toggleSelect(row.conversationId),
      ));
    }

    return FutureBuilder<String>(
      key: ValueKey('row_${row.conversationId}'),
      future: _usernameFor(row.peerUid),
      builder: (context, nameSnap) {
        final username = nameSnap.data ?? '…';
        return _withSwipeActions(scheme, row, ListTile(
          selected: _selected.contains(row.conversationId),
          selectedTileColor: scheme.primary.withValues(alpha: 0.14),
          leading: _selectBadge(scheme, row, UserAvatar(uid: row.peerUid, name: username)),
          title: Text(username, style: emphasize ? const TextStyle(fontWeight: FontWeight.w700) : null),
          subtitle: row.draftText != null
              ? _draftSubtitle(scheme, row.draftText!)
              : Text(
                  row.lastText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: row.isPlaceholder ? TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic) : null,
                ),
          trailing: trailing,
          onTap: () async {
            if (_selecting) {
              _toggleSelect(row.conversationId);
              return;
            }
            if (!await requireChatPinIfLocked(context, row.conversationId)) return;
            if (!context.mounted) return;
            // The chat screen shows my nickname in its title by itself; it
            // is given the REAL username so everything else stays accurate.
            final realName = await _realUsernameFor(row.peerUid);
            if (!context.mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatDetailScreen(conversationId: row.conversationId, peerUid: row.peerUid, peerUsername: realName),
              ),
            );
            await _loadHiddenIds();
          },
          onLongPress: () => _toggleSelect(row.conversationId),
        ));
      },
    );
  }
}

/// Feature: home screen background — renders whatever HomeBackgroundService
/// currently has set (a preset from the same set chats use, or a custom
/// photo) behind the whole home screen. Reloads itself whenever
/// HomeBackgroundService.changes ticks, so picking a new one in
/// HomeBackgroundScreen updates this immediately if it's still mounted.
class _HomeBackgroundView extends StatefulWidget {
  const _HomeBackgroundView();
  @override
  State<_HomeBackgroundView> createState() => _HomeBackgroundViewState();
}

class _HomeBackgroundViewState extends State<_HomeBackgroundView> {
  ChatWallpaper? _background;

  @override
  void initState() {
    super.initState();
    HomeBackgroundService.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    HomeBackgroundService.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final w = await HomeBackgroundService.getBackground();
    if (mounted) setState(() => _background = w);
  }

  @override
  Widget build(BuildContext context) {
    final w = _background;
    if (w == null || (w.colors.isEmpty && w.imagePath == null)) return const SizedBox.shrink();
    return DecoratedBox(decoration: w.decoration());
  }
}
