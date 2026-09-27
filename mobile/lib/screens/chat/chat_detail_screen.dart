import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/local_message.dart';
import '../../services/auth_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/chat_wallpaper_service.dart';
import '../../services/inactivity_wipe_service.dart';
import '../../services/conversation_service.dart';
import '../../services/local_message_store.dart';
import '../../services/media_compression_service.dart';
import '../../services/media_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/moderation_service.dart';
import '../../services/pin_service.dart';
import '../../services/presence_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../services/signal_session_service.dart';
import '../../services/media_vault_service.dart';
import '../../services/private_keyboard_service.dart';
import '../../services/scheduled_message_service.dart';
import '../../widgets/schedule_send_sheet.dart';
import '../../services/voice_recording_controller.dart';
import '../../widgets/attachment_menu.dart';
import '../../widgets/live_location_share_sheet.dart';
import '../../widgets/live_location_bubble.dart';
import '../../widgets/media_viewer_screen.dart';
import '../../widgets/message_link_text.dart';
import '../../widgets/view_once_media_screen.dart';
import '../../widgets/voice_message_bubble.dart';
import '../../widgets/voice_recording_bar.dart';
import 'chat_search_screen.dart';
import 'forward_destination_screen.dart';
import 'media_preview_screen.dart';
import 'scheduled_messages_screen.dart';
import '../vault/media_vault_screen.dart';
import '../security/pin_screen.dart';
import '../security/safety_number_screen.dart';
import 'chat_settings_screen.dart';
import '../../widgets/chat_theme_scope.dart';
import '../../widgets/user_avatar.dart';

// Expanded quick-reaction set (was 6, now 12) — tapping the same emoji you
// already reacted with removes it; tapping a different one switches to it.
const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉', '😍', '👏', '💯', '😡'];

/// The chat screen. This thin outer widget only applies the chat's own
/// colour theme (see ChatThemeScope); everything else lives in
/// [_ChatDetailBody] below, unchanged.
class ChatDetailScreen extends StatelessWidget {
  final String conversationId;
  final String peerUid;
  final String peerUsername;

  const ChatDetailScreen({
    super.key,
    required this.conversationId,
    required this.peerUid,
    required this.peerUsername,
  });

  @override
  Widget build(BuildContext context) {
    return ChatThemeScope(
      conversationId: conversationId,
      child: _ChatDetailBody(conversationId: conversationId, peerUid: peerUid, peerUsername: peerUsername),
    );
  }
}

class _ChatDetailBody extends StatefulWidget {
  final String conversationId;
  final String peerUid;
  final String peerUsername;

  const _ChatDetailBody({
    required this.conversationId,
    required this.peerUid,
    required this.peerUsername,
  });

  @override
  State<_ChatDetailBody> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<_ChatDetailBody> {
  final _conversationService = ConversationService();
  final _moderationService = ModerationService();
  final _textController = TextEditingController();
  // Feature: message drafts — debounce timer for the periodic save while
  // typing; see _onTextChanged and dispose().
  Timer? _draftSaveTimer;
  final _scrollController = ScrollController();
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  // PERFORMANCE BUGFIX ("chats getting very laggy... auto move" as message
  // count grows) — three separate, compounding problems found in the
  // message list below, all fixed together here:
  //
  // 1. The auto-scroll-to-bottom below used to run UNCONDITIONALLY on
  //    EVERY emission of the messages stream — not just when a genuinely
  //    new message arrived. That stream re-emits for edits, deletions,
  //    reactions, and read-receipt status changes too, not only new
  //    messages, so someone scrolled up reading old messages would keep
  //    getting yanked back to the bottom by things that had nothing to do
  //    with new messages — this is almost certainly the "auto move"
  //    being reported. Fixed below: a jump to bottom now only happens on
  //    this screen's very first frame, or when the LAST message actually
  //    changed (a real new message arrived) AND the person was already
  //    near the bottom or the new message is their own.
  // 2. Building each message's media-gallery (for the swipeable photo/video
  //    viewer) used to filter + map + indexWhere over the ENTIRE messages
  //    list — INSIDE itemBuilder, i.e. once per VISIBLE ROW, not once per
  //    build. That's O(messages²) work every time the list rebuilds, and
  //    it gets quadratically worse as a chat's history grows — exactly
  //    "very laggy... when a lot of messages come". Fixed below: computed
  //    ONCE per build, outside itemBuilder.
  // 3. Finding a replied-to message used to linear-scan the entire
  //    messages list for every row that was a reply — same O(N²) shape as
  //    #2. Fixed below with a single id->message lookup map, built once.
  bool _stickToBottom = true; // whether the person is at/near the bottom right now
  int _lastMessageCount = 0;
  String? _lastMessageId;
  bool _didInitialScroll = false;

  void _onScrollPositionChanged() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Comfortably generous — anything closer than a screen-ish of content
    // from the bottom still counts as "reading the latest", so a new
    // message from the other person naturally scrolls into view instead
    // of leaving them to notice it landed just out of sight.
    _stickToBottom = (pos.maxScrollExtent - pos.pixels) < 400;
  }

  LocalMessage? _replyingTo;

  /// Non-null while composing an edit to a previously-sent text message
  /// (see _editSelected / MessageRelayService.editMessage) — mutually
  /// exclusive with [_replyingTo], the same way WhatsApp/Telegram only
  /// let you do one or the other at a time.
  LocalMessage? _editingMessage;
  List<String> _pinnedIds = [];
  int _pinnedBannerIndex = 0;
  bool _readReceiptsEnabled = true;
  bool _peerBlockedByMe = false;
  bool _sendingMedia = false;

  // Feature: "clear on exit" ephemeral view mode (ConversationService.
  // setEphemeralViewEnabled). Kept in sync with the conversation doc via
  // _convoSub, same as _chatTtlOverride right below it. See dispose()
  // for the actual clear — this field only tracks whether it's currently
  // turned on.
  bool _ephemeralViewEnabled = false;
  // Feature: anti-tampering / MITM re-verification prompts. Checked once,
  // proactively, when this chat is opened — see initState — independent
  // of the existing reactive IdentityChangedException path that only
  // fires when a SEND happens to need a brand-new session.
  bool _identityChanged = false;

  // Feature: more 1:1 chat security settings — "Lock this chat" (see
  // ChatSettingsScreen). [_isChatLocked] just records whether THIS chat
  // is configured to require a PIN; [_chatUnlockedThisSession] is what
  // actually gates the UI below and starts false whenever locking is on,
  // requiring a fresh PIN entry (via AppLockService/PinScreen) every time
  // this screen opens — it does NOT persist across re-opening the chat,
  // on purpose, the same way the feature is meant to work.
  bool _isChatLocked = false;
  bool _chatUnlockedThisSession = true;

  // Feature: unified voice/media UI (chat + group) — shared controller
  // instead of this screen's own duplicated recording state/logic.
  late final _voiceController = VoiceRecordingController(
    onTick: () => setState(() {}),
    onMaxLengthReached: _stopAndSendVoiceRecording,
  );

  // WhatsApp-style long-press-to-select: long-pressing a bubble enters
  // selection mode and highlights it; the app bar swaps to show the
  // selected count and the available actions (react/reply/pin only make
  // sense for exactly one selection; copy/delete work for any number).
  final Set<String> _selectedIds = {};
  final Map<String, GlobalKey> _bubbleKeys = {};
  List<LocalMessage> _messages = [];

  // Feature: "jump to unread" button. Captured once, in initState, before
  // this screen has a chance to mark anything read — see
  // LocalMessageStore.getFirstUnreadId's own doc comment. Cleared once
  // tapped (a one-shot indicator, not a live "still unread" tracker).
  String? _firstUnreadId;

  // Feature: chat wallpapers/themes per conversation. Local-only, see
  // ChatWallpaperService. Defaults to kChatWallpapers.first ("Default"
  // — empty colors list, meaning "use the existing dot-grid look").
  ChatWallpaper _wallpaper = kChatWallpapers.first;

  Future<void> _loadWallpaper() async {
    final w = await ChatWallpaperService.getWallpaper(widget.conversationId);
    if (mounted) setState(() => _wallpaper = w);
  }

  // Feature: permission-gated message forwarding. The live conversation doc
  // (kept current by _convoSub below) — forwarding on/off and any pending
  // request are read from it via ConversationService's forwarding helpers.
  Map<String, dynamic> _convoData = {};

  // Feature: screenshot alert — throttles notices so holding the buttons
  // down or mashing them can't flood the other person.
  DateTime? _lastScreenshotNoticeAt;

  int? _profileTtlHours;
  int? _chatTtlOverride;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _convoSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _blockSub;

  int get _effectiveTtlHours => _chatTtlOverride ?? _profileTtlHours ?? 0; // 0 = never — opt-in disappearing messages

  @override
  void initState() {
    super.initState();
    // Feature: message drafts — restore whatever was left unsent last time
    // this chat was open. Only fills the box if it's still empty (it will
    // be, this early in initState) so it never clobbers anything.
    LocalMessageStore.getDraft(widget.conversationId).then((draft) {
      if (mounted && draft != null && _textController.text.isEmpty) {
        setState(() => _textController.text = draft);
      }
    });
    // Feature: "jump to unread" button. Fired first, before anything
    // else in initState — best-effort race against markConversationRead
    // (called from the message StreamBuilder in build(), not from here),
    // to capture what was unread at the moment this screen opened.
    LocalMessageStore.getFirstUnreadId(widget.conversationId).then((id) {
      if (mounted) setState(() => _firstUnreadId = id);
    });
    _loadWallpaper();
    // Feature: "Mark as unread" — opening the chat is what clears it. (The
    // normal mark-read path below only runs when there are real unread
    // messages, so a chat that was manually flagged needs this explicit
    // clear.)
    LocalMessageStore.setManualUnread(widget.conversationId, false);
    InactivityWipeService.recordOpened(widget.conversationId);
    // Screenshot / screen-recording prevention (Android FLAG_SECURE) —
    // see ScreenshotGuardService. Released in dispose() below.
    ScreenshotGuardService.acquire();
    // Feature: screenshot alert — while this chat is open, a screenshot
    // attempt (Android 14+) is reported to the other person.
    ScreenshotGuardService.onScreenshotDetected = _onScreenshotAttempt;
    _checkChatLock();
    _conversationService.ensureConversation(otherUid: widget.peerUid);
    SignalSessionService.instance.hasUnverifiedIdentityChange(widget.peerUid).then((changed) {
      if (mounted && changed) setState(() => _identityChanged = true);
    });
    // BUGFIX: messageTtlHours/readReceiptsEnabled moved to the owner-only
    // users/{uid}/private/profile doc (see firestore.rules) — read from
    // there now instead of the public users/{uid} doc.
    AuthService().currentUserPrivateProfile().then((doc) {
      if (!mounted) return;
      final data = doc.data();
      final peerDisabled = List<String>.from(data?['readReceiptsDisabledPeers'] ?? []).contains(widget.peerUid);
      setState(() {
        _profileTtlHours = (data?['messageTtlHours'] as num?)?.toInt();
        // Feature: granular 1:1 read-receipt privacy — off if EITHER the
        // global switch (Settings > Account security) is off, OR this
        // specific peer is in readReceiptsDisabledPeers (set from this
        // chat's own Chat Settings screen).
        _readReceiptsEnabled = ((data?['readReceiptsEnabled'] as bool?) ?? true) && !peerDisabled;
      });
    });
    _convoSub = _conversationService.conversationStream(widget.conversationId).listen((doc) {
      if (!mounted) return;
      setState(() {
        _convoData = doc.data() ?? {};
        _chatTtlOverride = (doc.data()?['chatTtlHours'] as num?)?.toInt();
        _ephemeralViewEnabled = doc.data()?['ephemeralViewEnabled'] == true;
      });
    });
    _blockSub = _moderationService.myProfileStream().listen((doc) {
      if (!mounted) return;
      final blocked = List<String>.from(doc.data()?['blockedUsers'] ?? []);
      setState(() => _peerBlockedByMe = blocked.contains(widget.peerUid));
    });
    PinService.pinnedFor(widget.conversationId).then((ids) {
      if (mounted) setState(() => _pinnedIds = ids);
    });
    // PERFORMANCE BUGFIX — see this class's field-level doc comment above
    // for the full explanation. Tracks whether the person is currently
    // scrolled near the bottom, so new messages only auto-scroll into
    // view when that's actually where their attention already is.
    _scrollController.addListener(_onScrollPositionChanged);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScrollPositionChanged);
    if (ScreenshotGuardService.onScreenshotDetected == _onScreenshotAttempt) {
      ScreenshotGuardService.onScreenshotDetected = null;
    }
    ScreenshotGuardService.release();
    _conversationService.setTyping(widget.conversationId, false);
    // Feature: message drafts — whatever's left in the compose bar when
    // this screen actually closes is saved (or, if it's now empty because
    // it was sent, cleared) — see LocalMessageStore.saveDraft. Skipped
    // while mid-edit of an existing message (_editingMessage != null):
    // that text is the ORIGINAL message being edited, not a new draft,
    // and saving it here would wrongly turn a cancelled edit into a
    // "draft" for a brand-new message next time this chat opens.
    _draftSaveTimer?.cancel();
    if (_editingMessage == null) {
      LocalMessageStore.saveDraft(widget.conversationId, _textController.text);
    }
    // Feature: "clear on exit" ephemeral view mode. Fires exactly once,
    // right as this exact conversationId's screen is actually leaving the
    // widget tree (back gesture, back button, or any other pop) —
    // NEVER on the app merely being backgrounded, since that pauses this
    // screen without disposing it. Scoped to widget.conversationId only —
    // this can never wipe any OTHER conversation, so re-entering any
    // other chat afterward is completely unaffected. This is purely
    // local: nothing is sent to the relay and the other person's device
    // is never touched by this.
    if (_ephemeralViewEnabled) {
      LocalMessageStore.clearConversation(widget.conversationId);
    }
    _convoSub?.cancel();
    _blockSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _voiceController.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _conversationService.setTyping(widget.conversationId, value.isNotEmpty);
    // Feature: message drafts — lightly debounced so a draft survives the
    // app being killed by the OS while this chat is still open, not just
    // a normal navigate-away (dispose() above handles that case already).
    // Skipped while editing an existing message — see dispose()'s comment.
    if (_editingMessage == null) {
      _draftSaveTimer?.cancel();
      _draftSaveTimer = Timer(const Duration(milliseconds: 800), () {
        LocalMessageStore.saveDraft(widget.conversationId, _textController.text);
      });
    }
    setState(() {}); // toggles the compose bar between the mic icon and the send icon
  }

  Future<void> _checkChatLock() async {
    final locked = await ChatLockService.isLocked(widget.conversationId);
    if (!locked || !mounted) return;
    setState(() {
      _isChatLocked = true;
      _chatUnlockedThisSession = false;
    });
  }

  Future<void> _unlockChatNow() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.verify)),
    );
    if (!mounted) return;
    if (result == true) {
      setState(() => _chatUnlockedThisSession = true);
    } else {
      // Wrong PIN or backed out — don't leave the chat sitting half-open,
      // just back out of it entirely, same as tapping the app back button.
      Navigator.of(context).pop();
    }
  }

  Widget _buildLockedPlaceholder() {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.peerUsername)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              const Text('This chat is locked', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                'Enter your PIN to open it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _unlockChatNow, child: const Text('Unlock')),
            ],
          ),
        ),
      ),
    );
  }

  GlobalKey _bubbleKeyFor(String id) => _bubbleKeys.putIfAbsent(id, () => GlobalKey());

  /// Feature: date separators. A plain calendar-day comparison — local
  /// device time, not UTC, so "Today" matches what the person actually
  /// sees on their own clock.
  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatDateSeparator(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final sameYear = dt.year == now.year;
    return sameYear ? '${dt.day} ${months[dt.month - 1]}' : '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  void _jumpToMessage(String id) {
    final ctx = _bubbleKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.5);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Scroll to find this message — it's outside the loaded view")),
      );
    }
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// Shown when SignalSessionService reports that a contact's encryption
  /// keys have changed since the last time a session was established with
  /// them — usually a reinstall or new device, but exactly the kind of
  /// thing a real secure messenger asks about rather than silently
  /// re-trusting. Returns true if the person explicitly chose to trust the
  /// new key and retry.
  Future<bool> _confirmIdentityChangeAndRetry() async {
    final trust = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Security code changed'),
        content: Text(
          "${widget.peerUsername}'s encryption keys have changed since you last talked. "
          "This usually just means they reinstalled the app or got a new device — but it's "
          "also what it would look like if something were wrong. Send anyway?",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Trust & send')),
        ],
      ),
    );
    if (trust != true) return false;
    try {
      await SignalSessionService.instance.acceptChangedIdentityAndRetry(widget.peerUid);
      return true;
    } catch (_) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't confirm the new key — please try again.")),
      );
      return false;
    }
  }

  Future<void> _send({bool silent = false}) async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're not signed in. Please sign in again.")),
      );
      return;
    }
    if (_peerBlockedByMe) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unblock ${widget.peerUsername} first to send a message.')),
      );
      return;
    }

    // Editing an existing message takes a completely separate path from
    // sending a new one — no reply/TTL/media handling applies to an edit.
    final editing = _editingMessage;
    if (editing != null) {
      _textController.clear();
      _draftSaveTimer?.cancel();
      setState(() => _editingMessage = null);
      try {
        await MessageRelayService.editMessage(
          conversationId: widget.conversationId,
          toUid: widget.peerUid,
          messageId: editing.id,
          newText: text,
          originalCreatedAt: editing.createdAt,
        );
      } on ChatFrozenException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      } on RateLimitedException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save edit — $e")));
      }
      return;
    }

    _textController.clear();
    _draftSaveTimer?.cancel();
    LocalMessageStore.clearDraft(widget.conversationId);
    final replyId = _replyingTo?.id;
    setState(() => _replyingTo = null);
    Future<void> attemptSend() async {
      await MessageRelayService.sendMessage(
        conversationId: widget.conversationId,
        recipientUid: widget.peerUid,
        text: text,
        replyToId: replyId,
        ttlHours: _effectiveTtlHours,
        // Feature: silent send — delivered normally, no notification on
        // their phone.
        silent: silent,
      );
      if (silent && mounted) _showForwardSnack('Sent silently — no notification on their phone.');
    }
    try {
      await attemptSend();
    } on IdentityChangedException catch (_) {
      if (!mounted) return;
      final trusted = await _confirmIdentityChangeAndRetry();
      if (!trusted) {
        // Give the text back rather than silently discarding what they typed.
        if (mounted) _textController.text = text;
        return;
      }
      try {
        await attemptSend();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message not sent — $e'), duration: const Duration(seconds: 6)));
      }
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on BlockedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on ChatFrozenException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on RateLimitedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message not sent — $e'), duration: const Duration(seconds: 6)));
    }
    await _conversationService.setTyping(widget.conversationId, false);
  }

  // ---- Feature: send options (silent / send later) ------------------------

  /// Press-and-hold on the send button. Only when there's text to send and
  /// the compose bar isn't editing an existing message.
  Future<void> _showSendOptions() async {
    if (_editingMessage != null || _textController.text.trim().isEmpty || _sendingMedia) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Send silently'),
              subtitle: const Text('Delivered as normal, but no notification on their phone'),
              onTap: () => Navigator.pop(sheetContext, 'silent'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Send later…'),
              subtitle: const Text('Pick a time — it sends from this phone'),
              onTap: () => Navigator.pop(sheetContext, 'later'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'silent') {
      await _send(silent: true);
    } else if (choice == 'later') {
      await _scheduleCurrentMessage();
    }
  }

  /// Queues what's in the compose bar to be sent later (see
  /// ScheduledMessageService for how, and its honest limit).
  Future<void> _scheduleCurrentMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _editingMessage != null) return;
    if (_peerBlockedByMe) {
      _showForwardSnack('Unblock ${widget.peerUsername} first.');
      return;
    }
    final choice = await showScheduleSendSheet(context);
    if (choice == null || !mounted) return;
    await ScheduledMessageService.instance.schedule(
      conversationId: widget.conversationId,
      peerUid: widget.peerUid,
      peerUsername: widget.peerUsername,
      text: text,
      sendAt: choice.sendAt,
      silent: choice.silent,
      ttlHours: _effectiveTtlHours,
      replyToId: _replyingTo?.id,
    );
    _textController.clear();
    _draftSaveTimer?.cancel();
    LocalMessageStore.clearDraft(widget.conversationId);
    setState(() => _replyingTo = null);
    await _conversationService.setTyping(widget.conversationId, false);
    _showForwardSnack('Scheduled for ${formatScheduledTime(choice.sendAt)}${choice.silent ? ' (silent)' : ''}.');
  }

  /// The "N scheduled" bar above the compose box — appears only while this
  /// chat has something waiting.
  Widget _buildScheduledBanner(ColorScheme scheme) {
    return ValueListenableBuilder<List<ScheduledMessage>>(
      valueListenable: ScheduledMessageService.instance.items,
      builder: (context, all, _) {
        final mine = all.where((m) => m.conversationId == widget.conversationId).toList();
        if (mine.isEmpty) return const SizedBox.shrink();
        final failed = mine.where((m) => m.isFailed).length;
        return Material(
          color: failed > 0 ? scheme.errorContainer : scheme.secondaryContainer,
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ScheduledMessagesScreen(conversationId: widget.conversationId, title: widget.peerUsername),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    failed > 0 ? Icons.warning_amber_rounded : Icons.schedule,
                    size: 18,
                    color: failed > 0 ? scheme.onErrorContainer : scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      failed > 0
                          ? '${mine.length} scheduled · $failed need${failed == 1 ? 's' : ''} your attention'
                          : '${mine.length} scheduled · next ${formatScheduledTime(mine.first.sendAt)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: failed > 0 ? scheme.onErrorContainer : scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: failed > 0 ? scheme.onErrorContainer : scheme.onSecondaryContainer),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Entry point for the "Edit" selection-app-bar action — only offered
  /// (see the selection app bar below) for a single selected message that
  /// is ours, is plain text, and is still inside
  /// MessageRelayService.editWindow. Pre-fills the compose bar with the
  /// current text, same as WhatsApp/Telegram's edit flow.
  void _editSelected() {
    if (_selectedIds.length != 1) return;
    LocalMessage? message;
    for (final m in _messages) {
      if (m.id == _selectedIds.first) {
        message = m;
        break;
      }
    }
    if (message == null) return;
    setState(() {
      _editingMessage = message;
      _replyingTo = null;
      _selectedIds.clear();
      _textController.text = message!.text;
      _textController.selection = TextSelection.collapsed(offset: message.text.length);
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingMessage = null;
      _textController.clear();
    });
  }

  Future<void> _openSearch() async {
    final targetId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ChatSearchScreen(conversationId: widget.conversationId, peerUsername: widget.peerUsername),
      ),
    );
    if (targetId != null) _jumpToMessage(targetId);
  }

  void _showAttachSheet() {
    if (_peerBlockedByMe) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unblock ${widget.peerUsername} first to send media.')),
      );
      return;
    }
    showAttachmentMenu(
      context,
      onCameraPhoto: () => _pickAndSendImage(ImageSource.camera),
      onGalleryPhoto: () => _pickAndSendImage(ImageSource.gallery),
      onCameraVideo: () => _pickAndSendVideo(ImageSource.camera),
      onGalleryVideo: () => _pickAndSendVideo(ImageSource.gallery),
      // The separate "view once" entries are gone from this menu: view once is
      // now a switch inside the preview that opens after you pick something.
      onLiveLocation: () => showLiveLocationShareSheet(
        context,
        conversationId: widget.conversationId,
        recipientUid: widget.peerUid,
      ),
    );
  }

  Future<void> _pickAndSendImage(ImageSource source, {bool viewOnce = false}) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 100);
    if (picked == null || !mounted) return;
    // Feature: media preview — look at it, crop/rotate/draw/add text, choose
    // "view once", THEN send. Backing out sends nothing.
    final result = await showMediaPreview(
      context,
      file: File(picked.path),
      isVideo: false,
      recipientLabel: widget.peerUsername,
      initialViewOnce: viewOnce,
    );
    if (result == null || !mounted) return;
    await _sendMedia(
      file: result.file,
      messageType: 'image',
      mime: 'image/jpeg',
      compress: (file) => MediaCompressionService.compressImage(file),
      viewOnce: result.viewOnce,
    );
  }

  Future<void> _pickAndSendVideo(ImageSource source, {bool viewOnce = false}) async {
    // Cap recording/selection length at 2 minutes — a longer clip is very
    // unlikely to compress under the 5MB cap at any watchable quality, so
    // it's better to stop the user before they wait through a compression
    // pass that's doomed to fail than after.
    final picked = await ImagePicker().pickVideo(source: source, maxDuration: const Duration(minutes: 2));
    if (picked == null || !mounted) return;
    final result = await showMediaPreview(
      context,
      file: File(picked.path),
      isVideo: true,
      recipientLabel: widget.peerUsername,
      initialViewOnce: viewOnce,
    );
    if (result == null || !mounted) return;
    await _sendMedia(
      file: result.file,
      messageType: 'video',
      mime: 'video/mp4',
      compress: (file) async => (await MediaCompressionService.compressVideo(file)).readAsBytesSync(),
      viewOnce: result.viewOnce,
    );
  }

  Future<void> _sendMedia({
    required File file,
    required String messageType,
    required String mime,
    required Future<List<int>> Function(File) compress,
    bool viewOnce = false,
  }) async {
    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're not signed in. Please sign in again.")),
      );
      return;
    }
    setState(() => _sendingMedia = true);
    try {
      final bytes = await compress(file);
      Future<void> attemptSend() => MessageRelayService.sendMediaMessage(
            conversationId: widget.conversationId,
            recipientUid: widget.peerUid,
            plainBytes: bytes,
            messageType: messageType,
            extension: messageType == 'image' ? 'jpg' : 'mp4',
            mime: mime,
            ttlHours: _effectiveTtlHours,
            isViewOnce: viewOnce,
          );
      try {
        await attemptSend();
      } on IdentityChangedException catch (_) {
        if (!mounted) return;
        if (await _confirmIdentityChangeAndRetry()) {
          await attemptSend();
        }
      }
    } on MediaTooLargeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on BlockedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on ChatFrozenException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on RateLimitedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message not sent — $e'), duration: const Duration(seconds: 6)));
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  /// Compression approach for voice, compared to photo/video: instead of
  /// recording at full quality and shrinking the file afterwards, we
  /// record directly at a low, speech-appropriate bitrate (64kbps mono
  /// AAC) and cap length at 5 minutes — that combination mathematically
  /// can't exceed ~2.3MB, comfortably under the 5MB limit, with no
  /// separate post-processing pass needed (and no quality surprises the
  /// way transcoding a video after the fact can have). Recording
  /// start/stop/cancel/timer logic itself now lives in the shared
  /// VoiceRecordingController (see [_voiceController]) — see the feature
  /// note on that class for why.
  Future<void> _startVoiceRecording() async {
    if (_peerBlockedByMe) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unblock ${widget.peerUsername} first to send voice messages.')),
      );
      return;
    }
    if (!await _voiceController.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is needed to record a voice message.')),
      );
      return;
    }
    await _voiceController.start();
  }

  Future<void> _cancelVoiceRecording() => _voiceController.cancel();

  Future<void> _stopAndSendVoiceRecording() async {
    final result = await _voiceController.stopAndFinish();
    if (result == null) return;
    final (file, durationMs) = result;

    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're not signed in. Please sign in again.")),
      );
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      Future<void> attemptSend() => MessageRelayService.sendMediaMessage(
            conversationId: widget.conversationId,
            recipientUid: widget.peerUid,
            plainBytes: bytes,
            messageType: 'voice',
            extension: 'm4a',
            mime: 'audio/mp4',
            durationMs: durationMs,
            ttlHours: _effectiveTtlHours,
          );
      try {
        await attemptSend();
      } on IdentityChangedException catch (_) {
        if (!mounted) return;
        if (await _confirmIdentityChangeAndRetry()) {
          await attemptSend();
        }
      }
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on BlockedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on ChatFrozenException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on RateLimitedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      // Feature: upload progress + retry — sendMediaMessage now leaves a
      // real 'failed' bubble in the chat on error instead of the send
      // just vanishing, so this snackbar is a courtesy notice, not the
      // only sign anything went wrong.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message not sent — $e'), duration: const Duration(seconds: 6)));
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Retries a photo/video/voice message that failed to send (status
  /// 'failed' — see MessageRelayService.sendMediaMessage/
  /// retryMediaMessage). Tapped from the bubble's own "Tap to retry" row.
  Future<void> _retryMediaSend(String clientId) async {
    try {
      await MessageRelayService.retryMediaMessage(clientId);
    } on IdentityChangedException catch (_) {
      if (!mounted) return;
      if (await _confirmIdentityChangeAndRetry()) {
        try {
          await MessageRelayService.retryMediaMessage(clientId);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Still couldn\'t send — $e')));
        }
      }
    } on ChatFrozenException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on RateLimitedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Still couldn\'t send — $e')));
    }
  }

  void _showReactionPicker(LocalMessage message) {
    final uid = _myUid;
    final myCurrent = uid != null ? message.reactions[uid] : null;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (final emoji in _quickReactions)
                _ReactionOption(
                  emoji: emoji,
                  selected: myCurrent == emoji,
                  onTap: () {
                    final tapUid = _myUid;
                    if (tapUid == null) return;
                    // Tapping the reaction you already picked removes it
                    // instead of re-adding it — matches the "tap it again
                    // to remove" behavior most reaction pickers use.
                    final newEmoji = myCurrent == emoji ? null : emoji;
                    LocalMessageStore.setReaction(message.id, tapUid, newEmoji);
                    MessageRelayService.sendReaction(
                      conversationId: widget.conversationId,
                      toUid: widget.peerUid,
                      messageId: message.id,
                      emoji: newEmoji,
                    );
                    Navigator.pop(sheetContext);
                  },
                ),
              if (myCurrent != null)
                IconButton(
                  iconSize: 28,
                  tooltip: 'Remove reaction',
                  onPressed: () {
                    final tapUid = _myUid;
                    if (tapUid == null) return;
                    LocalMessageStore.setReaction(message.id, tapUid, null);
                    MessageRelayService.sendReaction(
                      conversationId: widget.conversationId,
                      toUid: widget.peerUid,
                      messageId: message.id,
                      emoji: null,
                    );
                    Navigator.pop(sheetContext);
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tapping the small reaction chip under a bubble directly (not the
  /// long-press menu): if it's your own reaction, this removes it
  /// immediately — no picker needed. Otherwise it opens the picker.
  void _onTapReactionChip(LocalMessage message) {
    final uid = _myUid;
    if (uid == null) {
      _showReactionPicker(message);
      return;
    }
    final mine = message.reactions[uid];
    if (mine != null) {
      LocalMessageStore.setReaction(message.id, uid, null);
      MessageRelayService.sendReaction(
        conversationId: widget.conversationId,
        toUid: widget.peerUid,
        messageId: message.id,
        emoji: null,
      );
    } else {
      _showReactionPicker(message);
    }
  }

  void _reactToSelected() {
    if (_selectedIds.length != 1) return;
    final id = _selectedIds.first;
    final msg = _messages.where((m) => m.id == id).toList();
    setState(() => _selectedIds.clear());
    if (msg.isNotEmpty) _showReactionPicker(msg.first);
  }

  void _replyToSelected() {
    if (_selectedIds.length != 1) return;
    final id = _selectedIds.first;
    final msg = _messages.where((m) => m.id == id).toList();
    if (msg.isEmpty) return;
    setState(() {
      _replyingTo = msg.first;
      _selectedIds.clear();
    });
  }

  Future<void> _pinSelected() async {
    if (_selectedIds.length != 1) return;
    final id = _selectedIds.first;
    final error = await PinService.togglePin(widget.conversationId, id);
    final ids = await PinService.pinnedFor(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _pinnedIds = ids;
      _pinnedBannerIndex = 0;
      _selectedIds.clear();
    });
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// Feature: starred/saved messages, bulk version — works for any
  /// number selected, unlike Reply/React/Edit/Pin above which only make
  /// sense for exactly one message at a time. If the selection is a mix
  /// of already-starred and not-yet-starred messages, this stars all of
  /// them rather than trying to guess a toggle direction from a mixed
  /// state.
  Future<void> _starSelected() async {
    final ids = _selectedIds.toList();
    final allAlreadyStarred = _messages.where((m) => ids.contains(m.id)).every((m) => m.starred);
    await LocalMessageStore.setStarredBulk(ids, !allAlreadyStarred);
    if (mounted) setState(() => _selectedIds.clear());
  }

  // ---- Feature: screenshot alert -----------------------------------------

  /// Android told us the screenshot buttons were just pressed while this
  /// chat is open. The screenshot itself was already blocked (FLAG_SECURE);
  /// this tells the person WHY nothing was captured and quietly lets the
  /// other person know it was attempted.
  void _onScreenshotAttempt() {
    if (!mounted) return;
    final now = DateTime.now();
    final last = _lastScreenshotNoticeAt;
    if (last != null && now.difference(last) < const Duration(seconds: 10)) return;
    _lastScreenshotNoticeAt = now;
    _showForwardSnack('Screenshots are blocked in this chat — ${widget.peerUsername} was told you tried.');
    MessageRelayService.sendScreenshotNotice(
      conversationId: widget.conversationId,
      toUid: widget.peerUid,
      ttlHours: _effectiveTtlHours,
    );
  }

  /// The small centered line shown where the other person tried to take a
  /// screenshot (a 'screenshot_notice' message — see the relay service).
  Widget _buildScreenshotNotice(ColorScheme scheme, LocalMessage msg) {
    return Padding(
      key: _bubbleKeyFor(msg.id),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, size: 14, color: scheme.onErrorContainer),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${widget.peerUsername} tried to take a screenshot of this chat',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Feature: locked media vault ---------------------------------------

  /// The selected messages that CAN go into the vault: real photos/videos
  /// still on this device. View-once media never can — it's designed to
  /// disappear after one look, so keeping a copy would defeat the point.
  List<LocalMessage> _selectedMovableToVault() {
    return _messages
        .where((m) =>
            _selectedIds.contains(m.id) &&
            (m.messageType == 'image' || m.messageType == 'video') &&
            m.mediaPath != null &&
            !m.isViewOnce)
        .toList();
  }

  Future<void> _moveSelectedToVault() async {
    final movable = _selectedMovableToVault();
    if (movable.isEmpty) return;
    final vault = MediaVaultService.instance;

    if (!await vault.isSetUp()) {
      if (!mounted) return;
      final setUp = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.enhanced_encryption_outlined),
          title: const Text('Set up your media vault'),
          content: const Text(
            'The media vault is a locked, encrypted place on this phone for photos and videos, protected by its own PIN. '
            'Set it up first, then select these photos again to move them in.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Set up')),
          ],
        ),
      );
      if (setUp == true && mounted) {
        setState(() => _selectedIds.clear());
        Navigator.push(
          context,
          MaterialPageRoute(settings: const RouteSettings(name: '/vault'), builder: (_) => const MediaVaultScreen()),
        );
      }
      return;
    }

    if (!mounted) return;
    final count = movable.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Move $count ${count == 1 ? 'item' : 'items'} to your vault?'),
        content: Text(
          'They will be encrypted and locked behind your vault PIN, and removed from this chat on this phone only. '
          '${widget.peerUsername} keeps their own copy.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Move')),
        ],
      ),
    );
    if (confirmed != true) return;

    var moved = 0;
    for (final m in movable) {
      try {
        await vault.importFile(File(m.mediaPath!), isVideo: m.messageType == 'video');
        // Only removed from the chat AFTER the encrypted copy is safely in
        // the vault — a failed import leaves the original exactly where it was.
        await LocalMessageStore.deleteMessage(m.id);
        moved++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    _showForwardSnack(
      moved == count
          ? 'Moved to your vault'
          : (moved == 0 ? "Couldn't move these to the vault" : 'Moved $moved of $count to your vault'),
    );
  }

  void _copySelected() {
    // Feature: copy protection. Copying is only available where forwarding
    // is switched on for this chat (both people agreed). The button is
    // hidden otherwise, and this guard makes sure nothing else can reach
    // the clipboard path either.
    if (!_conversationService.isForwardingEnabled(_convoData)) {
      _showForwardSnack('Copying is restricted in this chat.');
      return;
    }
    final ordered = _messages.where((m) => _selectedIds.contains(m.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final text = ordered.map((m) => m.text).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _selectedIds.clear());
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  // ---- Feature: permission-gated message forwarding ----------------------

  void _showForwardSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runForwardingAction(Future<void> Function() action, String successMessage) async {
    try {
      await action();
      _showForwardSnack(successMessage);
    } catch (e) {
      _showForwardSnack("Couldn't update forwarding — check your connection and try again.");
    }
  }

  Future<void> _approveForwardRequest() => _runForwardingAction(
        () => _conversationService.approveForwardingRequest(widget.conversationId),
        'Forwarding turned on for this chat — either of you can switch it off any time.',
      );

  Future<void> _denyForwardRequest() => _runForwardingAction(
        () => _conversationService.clearForwardingRequest(widget.conversationId),
        'Request declined.',
      );

  /// The banner across the top of the chat when the OTHER person has asked
  /// to be able to forward messages and is waiting for an answer.
  Widget _buildForwardRequestBanner(ColorScheme scheme) {
    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.forward_to_inbox_outlined, size: 20, color: scheme.onTertiaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${widget.peerUsername} would like to be able to forward and copy messages from this chat. '
                    'If you allow it, either of you can forward and copy from here — and either of you can switch it off again at any time.',
                    style: TextStyle(fontSize: 13, color: scheme.onTertiaryContainer),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: _denyForwardRequest, child: const Text('Deny')),
                  const SizedBox(width: 4),
                  FilledButton(onPressed: _approveForwardRequest, child: const Text('Allow')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown instead of the destination picker when forwarding is off for this
  /// chat — explains why, and offers the right next step for whichever
  /// situation this chat is in (nothing asked yet / I already asked / the
  /// other person already asked me).
  Future<void> _showForwardingRestrictedDialog() async {
    final incoming = _conversationService.hasIncomingForwardingRequest(_convoData);
    final mine = _conversationService.hasMyPendingForwardingRequest(_convoData);
    final name = widget.peerUsername;
    final String body;
    final List<Widget> Function(BuildContext) actions;
    if (incoming) {
      body = '$name has asked to be able to forward and copy messages from this chat. Allow it and either of you will be able to '
          'forward and copy from here. You can switch it off again at any time, without asking.';
      actions = (c) => [
            TextButton(onPressed: () => Navigator.pop(c, 'deny'), child: const Text('Deny')),
            FilledButton(onPressed: () => Navigator.pop(c, 'approve'), child: const Text('Allow')),
          ];
    } else if (mine) {
      body = "You've already asked $name. They'll see your request the next time they open this chat.";
      actions = (c) => [
            TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Cancel request')),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ];
    } else {
      body = 'To protect privacy, messages in this chat can only be forwarded or copied if $name agrees first. '
          'If they allow it, either of you will be able to forward and copy from here — and either of you can switch it off '
          'again at any time.';
      actions = (c) => [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(c, 'request'), child: Text('Ask $name')),
          ];
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.shield_outlined),
        title: const Text('Forwarding is restricted'),
        content: Text(body),
        actions: actions(dialogContext),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'request':
        await _runForwardingAction(
          () => _conversationService.requestForwarding(widget.conversationId),
          'Request sent to $name.',
        );
        break;
      case 'approve':
        await _approveForwardRequest();
        break;
      case 'deny':
        await _denyForwardRequest();
        break;
      case 'cancel':
        await _runForwardingAction(
          () => _conversationService.clearForwardingRequest(widget.conversationId),
          'Request cancelled.',
        );
        break;
    }
  }

  /// The "Forward" button in the selection bar. Only ever offered for one
  /// plain text message (this first version doesn't forward media). If
  /// forwarding is off for this chat it explains and offers to ask;
  /// otherwise it opens the destination picker.
  Future<void> _forwardSelected() async {
    if (_selectedIds.length != 1) return;
    LocalMessage? message;
    for (final m in _messages) {
      if (m.id == _selectedIds.first) {
        message = m;
        break;
      }
    }
    if (message == null || message.messageType != 'text') return;
    final text = message.text;
    setState(() => _selectedIds.clear());

    if (!_conversationService.isForwardingEnabled(_convoData)) {
      await _showForwardingRestrictedDialog();
      return;
    }
    final forwardedTo = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ForwardDestinationScreen(
          sourceConversationId: widget.conversationId,
          sourcePeerUid: widget.peerUid,
          text: text,
        ),
      ),
    );
    if (forwardedTo != null) _showForwardSnack('Forwarded to $forwardedTo');
  }

  Future<void> _deleteSelectedFlow() async {
    final selected = _messages.where((m) => _selectedIds.contains(m.id)).toList();
    if (selected.isEmpty) return;
    final allMine = selected.every((m) => m.isMine);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text('Delete for me (${selected.length})'),
              onTap: () => Navigator.pop(sheetContext, 'me'),
            ),
            if (allMine)
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                title: Text(
                  'Delete for everyone (${selected.length})',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(sheetContext, 'everyone'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'me') {
      for (final m in selected) {
        await MessageRelayService.deleteForMe(m.id);
      }
    } else if (choice == 'everyone') {
      for (final m in selected) {
        await MessageRelayService.deleteForEveryone(
          conversationId: widget.conversationId,
          toUid: widget.peerUid,
          messageId: m.id,
        );
      }
    }
    if (mounted) setState(() => _selectedIds.clear());
  }

  @override
  Widget build(BuildContext context) {
    // Feature: "Lock this chat" (see ChatSettingsScreen + ChatLockService).
    // A single early return, before any of the normal chat UI below is
    // ever built — deliberately not folded into the Scaffold below it,
    // to keep this check isolated from (and safe alongside) everything
    // else this screen already does.
    if (_isChatLocked && !_chatUnlockedThisSession) {
      return _buildLockedPlaceholder();
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: _selectedIds.isEmpty ? _buildNormalAppBar(scheme) : _buildSelectionAppBar(scheme),
      floatingActionButton: _firstUnreadId == null
          ? null
          : FloatingActionButton.small(
              tooltip: 'Jump to unread',
              onPressed: () {
                _jumpToMessage(_firstUnreadId!);
                setState(() => _firstUnreadId = null);
              },
              child: const Icon(Icons.arrow_downward),
            ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _wallpaper.colors.isEmpty
                ? CustomPaint(painter: _DotGridPainter(color: scheme.onSurface.withValues(alpha: 0.05)))
                : Container(decoration: BoxDecoration(
                    color: _wallpaper.colors.length == 1 ? _wallpaper.colors.first : null,
                    gradient: _wallpaper.colors.length > 1 ? LinearGradient(colors: _wallpaper.colors, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
                  )),
          ),
          Column(
            children: [
              if (_pinnedIds.isNotEmpty) _buildPinnedBanner(scheme),
              if (_identityChanged) _buildIdentityChangedBanner(scheme),
              if (_conversationService.hasIncomingForwardingRequest(_convoData)) _buildForwardRequestBanner(scheme),
              if (_effectiveTtlHours > 0)
                Container(
                  width: double.infinity,
                  color: scheme.surfaceContainerHigh,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.timer_outlined, size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        'New messages disappear after ${_ttlLabel(_effectiveTtlHours)}'
                        '${_chatTtlOverride != null ? ' (set for this chat)' : ''}',
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: StreamBuilder<List<LocalMessage>>(
                  stream: LocalMessageStore.watchConversation(widget.conversationId),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    final messages = snapshot.data!;
                    _messages = messages;
                    if (messages.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mark_chat_read_outlined, size: 44, color: scheme.primary.withValues(alpha: 0.4)),
                            const SizedBox(height: 10),
                            Text('Say hello 👋', style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      );
                    }
                    // PERFORMANCE BUGFIX — see the field-level doc comment on
                    // _stickToBottom for the full explanation. Only jump to
                    // the bottom on this screen's very first frame, or when
                    // the actual LAST message changed (a genuinely new
                    // message, not an edit/reaction/receipt update
                    // somewhere earlier in the list) and the person was
                    // already near the bottom or it's their own message —
                    // never unconditionally on every rebuild.
                    final newLastId = messages.last.id;
                    final lastMessageChanged = newLastId != _lastMessageId;
                    final shouldScrollToBottom =
                        !_didInitialScroll || (lastMessageChanged && (_stickToBottom || messages.last.isMine));
                    _lastMessageCount = messages.length;
                    _lastMessageId = newLastId;

                    // PERFORMANCE BUGFIX — see the field-level doc comment
                    // above for the full explanation. Computed ONCE per
                    // build (not once per visible row) so opening a large
                    // chat, or one more message arriving, no longer costs
                    // O(messages²) work.
                    final mediaGalleryItems = <MediaViewerItem>[];
                    final mediaGalleryIndexById = <String, int>{};
                    for (final m in messages) {
                      if (m.mediaPath != null && !m.isViewOnce && (m.messageType == 'image' || m.messageType == 'video')) {
                        mediaGalleryIndexById[m.id] = mediaGalleryItems.length;
                        mediaGalleryItems.add(MediaViewerItem(path: m.mediaPath!, isVideo: m.messageType == 'video'));
                      }
                    }
                    final messageById = <String, LocalMessage>{for (final m in messages) m.id: m};

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (shouldScrollToBottom && _scrollController.hasClients) {
                        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                        _stickToBottom = true;
                      }
                      _didInitialScroll = true;
                      final unread = messages.where((m) => !m.isMine && m.status != 'read');
                      if (unread.isNotEmpty) {
                        LocalMessageStore.markConversationRead(widget.conversationId);
                        if (_readReceiptsEnabled) {
                          for (final m in unread) {
                            MessageRelayService.sendReadReceipt(
                              conversationId: widget.conversationId,
                              toUid: widget.peerUid,
                              ref: m.id,
                            );
                          }
                        }
                      }
                    });
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                      itemCount: messages.length,
                      itemBuilder: (context, i) {
                        final msg = messages[i];
                        // PERFORMANCE BUGFIX — O(1) map lookup instead of an
                        // O(N) linear scan per reply row (see the
                        // field-level doc comment above _stickToBottom).
                        final replySource = msg.replyToId != null ? messageById[msg.replyToId] : null;
                        final uid = _myUid;
                        // Feature: date separators, WhatsApp-style — a
                        // "Today"/"Yesterday"/date header appears above
                        // the first message of each calendar day. Checked
                        // against the PREVIOUS message in the (ascending)
                        // list, so this is purely a rendering concern —
                        // nothing here is stored or sent anywhere.
                        final showDateHeader = i == 0 || !_isSameDay(messages[i - 1].createdAt, msg.createdAt);
                        final Widget bubble = msg.messageType == 'screenshot_notice'
                            ? _buildScreenshotNotice(scheme, msg)
                            : KeyedSubtree(
                          key: _bubbleKeyFor(msg.id),
                          child: _MessageBubble(
                            id: msg.id,
                            isMine: msg.isMine,
                            text: msg.text,
                            messageType: msg.messageType,
                            mediaPath: msg.mediaPath,
                            createdAt: msg.createdAt,
                            replyPreview: replySource?.text,
                            reactions: msg.reactions.values.toList(),
                            myReaction: uid != null ? msg.reactions[uid] : null,
                            status: msg.isMine ? msg.status : null,
                            pinned: _pinnedIds.contains(msg.id),
                            selected: _selectedIds.contains(msg.id),
                            edited: msg.editedAt != null,
                            starred: msg.starred,
                            isViewOnce: msg.isViewOnce,
                            viewOnceConsumed: msg.viewOnceConsumed,
                            isForwarded: msg.isForwarded,
                            // PERFORMANCE BUGFIX — reuse the list/index map
                            // built once above instead of recomputing them
                            // from scratch for every single row.
                            mediaGallery: mediaGalleryItems,
                            mediaGalleryIndex: mediaGalleryIndexById[msg.id] ?? -1,
                            onLongPress: () => _toggleSelect(msg.id),
                            onTap: () {
                              if (_selectedIds.isNotEmpty) _toggleSelect(msg.id);
                            },
                            onTapReactionChip: () => _onTapReactionChip(msg),
                            onRetry: () => _retryMediaSend(msg.id),
                            onSwipeReply: () {
                              if (_selectedIds.isNotEmpty) return;
                              setState(() => _replyingTo = msg);
                            },
                          ),
                        );
                        if (!showDateHeader) return bubble;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _DateSeparator(label: _formatDateSeparator(msg.createdAt)),
                            bubble,
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _conversationService.typingStream(widget.conversationId),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const SizedBox.shrink();
                  final peerTyping = snapshot.data!.docs.any((d) {
                    if (d.id != widget.peerUid) return false;
                    final isTyping = (d.data()['isTyping'] as bool?) ?? false;
                    final updatedAt = d.data()['updatedAt'] as Timestamp?;
                    final recent = updatedAt != null && DateTime.now().difference(updatedAt.toDate()).inSeconds < 8;
                    return isTyping && recent;
                  });
                  if (!peerTyping) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _TypingPulse(color: scheme.primary),
                    ),
                  );
                },
              ),
              if (_editingMessage != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: scheme.surfaceContainerHigh,
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Editing message', maxLines: 1, overflow: TextOverflow.ellipsis)),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _cancelEdit,
                      ),
                    ],
                  ),
                )
              else if (_replyingTo != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: scheme.surfaceContainerHigh,
                  child: Row(
                    children: [
                      Container(width: 3, height: 28, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Replying to: ${_replyingTo!.text}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _replyingTo = null),
                      ),
                    ],
                  ),
                ),
              _buildScheduledBanner(scheme),
              if (_peerBlockedByMe)
                _buildBlockedBar(scheme)
              else if (_voiceController.isRecording)
                VoiceRecordingBar(
                  seconds: _voiceController.seconds,
                  onCancel: _cancelVoiceRecording,
                  onSend: _stopAndSendVoiceRecording,
                )
              else
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          onPressed: _sendingMedia ? null : _showAttachSheet,
                          icon: _sendingMedia
                              ? SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                                )
                              : Icon(Icons.add_circle_outline, color: scheme.primary),
                          tooltip: 'Attach photo or video',
                        ),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(24),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            child: TextField(
                              controller: _textController,
                              onChanged: _onTextChanged,
                              minLines: 1,
                              maxLines: 4,
                              // Feature: private keyboard mode (off by default).
                              enableSuggestions: !PrivateKeyboardService.enabled.value,
                              autocorrect: !PrivateKeyboardService.enabled.value,
                              enableIMEPersonalizedLearning: !PrivateKeyboardService.enabled.value,
                              decoration: const InputDecoration(
                                hintText: 'Message',
                                border: InputBorder.none,
                                filled: false,
                                contentPadding: EdgeInsets.symmetric(vertical: 10),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
                            ),
                          ),
                          // Press and hold the send button for "Send silently" /
                          // "Send later…" (only offered when there's text).
                          child: GestureDetector(
                            onLongPress: (_editingMessage == null && _textController.text.trim().isNotEmpty && !_sendingMedia)
                                ? _showSendOptions
                                : null,
                            child: IconButton(
                            onPressed: _sendingMedia
                                ? null
                                : (_editingMessage == null && _textController.text.trim().isEmpty
                                    ? _startVoiceRecording
                                    : _send),
                            icon: Icon(
                              _editingMessage != null
                                  ? Icons.check_rounded
                                  : (_textController.text.trim().isEmpty ? Icons.mic : Icons.arrow_upward_rounded),
                              color: scheme.onPrimary,
                            ),
                          ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBlockedBar(ColorScheme scheme) {
    return SafeArea(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: scheme.errorContainer.withValues(alpha: 0.35),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('You blocked ${widget.peerUsername}', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Unblock them to send and receive messages here.', textAlign: TextAlign.center),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await _moderationService.unblockUser(widget.peerUid);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${widget.peerUsername} unblocked')),
                );
              },
              child: const Text('Unblock'),
            ),
          ],
        ),
      ),
    );
  }

  /// Feature: anti-tampering / MITM re-verification prompts. Deliberately
  /// no silent "dismiss" — the two actions either resolve the mismatch
  /// (Trust) or take the person somewhere that helps them resolve it out
  /// of band (Verify safety number), matching how Signal treats this:
  /// a real identity-key change is exactly the class of thing that
  /// shouldn't be easy to wave away without looking at it.
  Widget _buildIdentityChangedBanner(ColorScheme scheme) {
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.gpp_maybe_outlined, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "${widget.peerUsername}'s security code changed",
                style: TextStyle(fontSize: 12.5, color: scheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SafetyNumberScreen(peerUid: widget.peerUid, peerUsername: widget.peerUsername)),
              ),
              child: const Text('Verify'),
            ),
            TextButton(onPressed: _trustNewIdentityFromBanner, child: const Text('Trust')),
          ],
        ),
      ),
    );
  }

  Future<void> _trustNewIdentityFromBanner() async {
    final trust = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Trust new security code?'),
        content: Text(
          "This usually just means ${widget.peerUsername} reinstalled the app or got a new device. "
          "If you're not sure, verify the new safety number with them directly first instead.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Trust')),
        ],
      ),
    );
    if (trust != true) return;
    try {
      await SignalSessionService.instance.acceptChangedIdentityAndRetry(widget.peerUid);
      if (mounted) setState(() => _identityChanged = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't confirm the new key — please try again.")),
      );
    }
  }

  Widget _buildPinnedBanner(ColorScheme scheme) {
    final index = _pinnedBannerIndex.clamp(0, _pinnedIds.length - 1);
    // Most-recently-pinned first, like WhatsApp/Telegram's pinned banner.
    final pinnedId = _pinnedIds[_pinnedIds.length - 1 - index];
    final match = _messages.where((m) => m.id == pinnedId).toList();
    final previewText = match.isNotEmpty ? match.first.text : 'Pinned message';
    return Material(
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => _jumpToMessage(pinnedId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.push_pin, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              if (_pinnedIds.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('${index + 1}/${_pinnedIds.length}', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
              Expanded(
                child: Text(previewText, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ),
              if (_pinnedIds.length > 1)
                IconButton(
                  icon: const Icon(Icons.expand_more, size: 20),
                  tooltip: 'Next pinned message',
                  onPressed: () => setState(() => _pinnedBannerIndex = (_pinnedBannerIndex + 1) % _pinnedIds.length),
                ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Unpin',
                onPressed: () async {
                  await PinService.unpin(widget.conversationId, pinnedId);
                  final ids = await PinService.pinnedFor(widget.conversationId);
                  if (!mounted) return;
                  setState(() {
                    _pinnedIds = ids;
                    _pinnedBannerIndex = 0;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  AppBar _buildNormalAppBar(ColorScheme scheme) {
    return AppBar(
      titleSpacing: 0,
      title: Row(
        children: [
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: PresenceService.watchUser(widget.peerUid),
            builder: (context, snapshot) {
              // A permission-denied error here just means this person has
              // last-seen sharing off, or has blocked you — the read is
              // now enforced server-side (see firestore.rules), so treat
              // any error the same as "presence unknown" rather than
              // falling back to a default.
              final online = snapshot.hasError ? false : ((snapshot.data?.data()?['online'] as bool?) ?? false);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  UserAvatar(uid: widget.peerUid, name: widget.peerUsername, radius: 18),
                  if (online)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.shade400,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: PresenceService.watchUser(widget.peerUid),
              builder: (context, snapshot) {
                // Same server-side gating as the avatar dot above: a denied
                // read (last-seen sharing off, or you're blocked) means we
                // simply don't show a status line at all, instead of the
                // old client-side lastSeenVisible check.
                final data = snapshot.hasError ? null : snapshot.data?.data();
                final online = (data?['online'] as bool?) ?? false;
                final lastSeen = data?['lastSeen'] as Timestamp?;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.peerUsername, overflow: TextOverflow.ellipsis),
                    if (data != null)
                      Text(
                        online ? 'Online' : _lastSeenLabel(lastSeen?.toDate()),
                        style: TextStyle(fontSize: 12, color: online ? scheme.primary : scheme.onSurfaceVariant),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search in chat',
          onPressed: _openSearch,
        ),
        IconButton(
          icon: const Icon(Icons.tune_rounded),
          tooltip: 'Chat settings',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatSettingsScreen(
                conversationId: widget.conversationId,
                peerUid: widget.peerUid,
                peerUsername: widget.peerUsername,
              ),
            ),
          ).then((_) => _loadWallpaper()),
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar(ColorScheme scheme) {
    final count = _selectedIds.length;
    final single = count == 1;
    // Edit is only offered when the single selected message is ours, is
    // plain text (not media/voice — see MessageRelayService.editMessage),
    // and is still inside the edit window — same constraints the send
    // path itself enforces, checked again here just to decide whether to
    // show the button at all.
    LocalMessage? singleMessage;
    if (single) {
      for (final m in _messages) {
        if (m.id == _selectedIds.first) {
          singleMessage = m;
          break;
        }
      }
    }
    final canEdit = singleMessage != null &&
        singleMessage.isMine &&
        singleMessage.messageType == 'text' &&
        DateTime.now().difference(singleMessage.createdAt) <= MessageRelayService.editWindow;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(() => _selectedIds.clear()),
      ),
      title: Text('$count selected'),
      actions: [
        if (single)
          IconButton(icon: const Icon(Icons.emoji_emotions_outlined), tooltip: 'React', onPressed: _reactToSelected),
        if (single)
          IconButton(icon: const Icon(Icons.reply_rounded), tooltip: 'Reply', onPressed: _replyToSelected),
        if (canEdit)
          IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Edit', onPressed: _editSelected),
        if (single)
          IconButton(
            icon: Icon(_pinnedIds.contains(_selectedIds.first) ? Icons.push_pin : Icons.push_pin_outlined),
            tooltip: 'Pin',
            onPressed: _pinSelected,
          ),
        // Feature: permission-gated forwarding. Always visible for a single
        // text message — when forwarding is off, tapping it explains why and
        // offers to ask the other person, rather than the button vanishing.
        if (single && singleMessage != null && singleMessage.messageType == 'text')
          IconButton(icon: const Icon(Icons.forward_rounded), tooltip: 'Forward', onPressed: _forwardSelected),
        // Feature: copy protection — Copy only exists in chats where
        // forwarding has been allowed by both people.
        if (_conversationService.isForwardingEnabled(_convoData))
          IconButton(icon: const Icon(Icons.copy_outlined), tooltip: 'Copy', onPressed: _copySelected),
        // Feature: locked media vault — only for photos/videos.
        if (_selectedMovableToVault().isNotEmpty)
          IconButton(icon: const Icon(Icons.enhanced_encryption_outlined), tooltip: 'Move to vault', onPressed: _moveSelectedToVault),
        IconButton(
          icon: Icon(single && _messages.any((m) => m.id == _selectedIds.first && m.starred) ? Icons.star : Icons.star_border),
          tooltip: 'Star',
          onPressed: _starSelected,
        ),
        IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: _deleteSelectedFlow),
      ],
    );
  }

  String _ttlLabel(int hours) {
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
  }

  String _lastSeenLabel(DateTime? lastSeen) {
    if (lastSeen == null) return 'Offline';
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inHours < 1) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Last seen ${diff.inHours}h ago';
    return 'Last seen ${diff.inDays}d ago';
  }
}

class _ReactionOption extends StatelessWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;
  const _ReactionOption({required this.emoji, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primaryContainer : Colors.transparent,
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 26)),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final bool isMine;
  final String text;
  final String messageType;
  final String? mediaPath;
  final DateTime createdAt;
  final String? replyPreview;
  final List<String> reactions;
  final String? myReaction;
  final String? status;
  final bool pinned;
  final bool selected;
  final bool edited;
  final bool starred;
  final bool isViewOnce;
  final bool viewOnceConsumed;
  final bool isForwarded;
  final String id;
  final List<MediaViewerItem> mediaGallery;
  final int mediaGalleryIndex;
  final VoidCallback onLongPress;
  final VoidCallback onTap;
  final VoidCallback onTapReactionChip;
  final VoidCallback onRetry;
  final VoidCallback onSwipeReply;

  const _MessageBubble({
    required this.id,
    required this.isMine,
    required this.text,
    this.messageType = 'text',
    this.mediaPath,
    required this.createdAt,
    required this.replyPreview,
    required this.reactions,
    required this.myReaction,
    required this.status,
    required this.pinned,
    required this.selected,
    this.edited = false,
    this.starred = false,
    this.isViewOnce = false,
    this.viewOnceConsumed = false,
    this.isForwarded = false,
    this.mediaGallery = const [],
    this.mediaGalleryIndex = -1,
    required this.onLongPress,
    required this.onTap,
    required this.onTapReactionChip,
    required this.onRetry,
    required this.onSwipeReply,
  });

  /// Feature: message timestamps with seconds — shown on the bottom-right
  /// corner of EVERY bubble (sent and received alike), unlike the
  /// tick-mark status row next to it which only ever applies to messages
  /// you sent. Formatted by hand (no intl DateFormat) to avoid pulling in
  /// a locale/formatting dependency for something this simple.
  static String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Full theme rebuild, 2026-09-12 — matches the same treatment just
    // applied to group_chat_screen.dart's bubbles: a touch more rounding
    // (was 18/4, now 20/5), a deliberate darker-blend gradient instead of
    // a flat-alpha one for "mine", and a new subtle gradient for
    // "theirs" too (previously flat surfaceContainerHigh) so both chat
    // surfaces in the app now share one consistent bubble language.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
      bottomLeft: Radius.circular(isMine ? 20 : 5),
      bottomRight: Radius.circular(isMine ? 5 : 20),
    );
    final bubbleGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isMine
          ? [scheme.primary, Color.lerp(scheme.primary, Colors.black, 0.12)!]
          : [scheme.surfaceContainerHigh, scheme.surfaceContainerHighest],
    );

    return Container(
      color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
      child: Dismissible(
        key: UniqueKey(),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (_) async {
          onSwipeReply();
          return false;
        },
        background: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.reply_rounded, color: scheme.primary),
          ),
        ),
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 4),
            child: Align(
              alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Icon(Icons.push_pin, size: 12, color: scheme.onSurfaceVariant),
                    ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      gradient: bubbleGradient,
                      borderRadius: radius,
                      boxShadow: [
                        BoxShadow(
                          color: isMine ? scheme.primary.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.08),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Feature: permission-gated forwarding — small label
                        // on any message that was forwarded from another chat.
                        if (isForwarded)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.forward, size: 12, color: (isMine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: 0.65)),
                                const SizedBox(width: 4),
                                Text(
                                  'Forwarded',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: (isMine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: 0.65),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (replyPreview != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: (isMine ? Colors.white : scheme.primary).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              replyPreview!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: isMine ? Colors.white70 : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (messageType == 'image' && isViewOnce)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _ViewOnceBubbleContent(id: id, path: mediaPath, isVideo: false, isMine: isMine, consumed: viewOnceConsumed),
                          )
                        else if (messageType == 'video' && isViewOnce)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _ViewOnceBubbleContent(id: id, path: mediaPath, isVideo: true, isMine: isMine, consumed: viewOnceConsumed),
                          )
                        else if (messageType == 'image' && mediaPath != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _ImageBubbleContent(path: mediaPath!, gallery: mediaGallery, galleryIndex: mediaGalleryIndex),
                          )
                        else if (messageType == 'video' && mediaPath != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _VideoBubbleContent(path: mediaPath!, gallery: mediaGallery, galleryIndex: mediaGalleryIndex),
                          )
                        else if (messageType == 'voice' && mediaPath != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: VoiceMessageBubble(path: mediaPath!, isMine: isMine),
                          )
                        else if (messageType == 'live_location')
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: LiveLocationBubble(payloadText: text, isMine: isMine),
                          ),
                        if (text.isNotEmpty && messageType != 'live_location')
                          RichText(
                            text: TextSpan(
                              style: TextStyle(color: isMine ? scheme.onPrimary : scheme.onSurface),
                              children: [
                                // Feature: in-app scam/phishing link warning — any
                                // URL inside this message becomes a tappable span
                                // that shows the real domain (and a heuristic
                                // warning if it looks off) before ever opening it.
                                // See widgets/message_link_text.dart.
                                ...linkifySpan(
                                  context,
                                  text,
                                  TextStyle(color: isMine ? scheme.onPrimary : scheme.onSurface),
                                  linkColor: isMine ? Colors.white : scheme.primary,
                                ),
                                if (edited)
                                  TextSpan(
                                    text: '  (edited)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: (isMine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: 0.6),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // Feature: starred/saved messages — a small
                              // persistent indicator right in the bubble,
                              // not just correct Star/Unstar wording in the
                              // menu, so a starred message is recognizable
                              // at a glance while scrolling.
                              if (starred) ...[
                                Icon(Icons.star, size: 11, color: isMine ? scheme.onPrimary.withValues(alpha: 0.8) : Colors.amber),
                                const SizedBox(width: 3),
                              ],
                              Text(
                                _formatTimestamp(createdAt),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: (isMine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: 0.65),
                                ),
                              ),
                              if (isMine && status != null) ...[
                                const SizedBox(width: 4),
                                _StatusIndicator(id: id, status: status!, isMine: isMine, onRetry: onRetry),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (reactions.isNotEmpty)
                    Transform.translate(
                      offset: const Offset(0, -8),
                      child: GestureDetector(
                        // Tapping the chip directly: if it contains your own
                        // reaction, this removes it immediately — otherwise
                        // it opens the picker.
                        onTap: onTapReactionChip,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: myReaction != null ? scheme.primaryContainer : scheme.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                          ),
                          child: Text(reactions.join(' '), style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingPulse extends StatefulWidget {
  final Color color;
  const _TypingPulse({required this.color});

  @override
  State<_TypingPulse> createState() => _TypingPulseState();
}

class _TypingPulseState extends State<_TypingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = (_controller.value + (i * 0.2)) % 1.0;
              final scale = 0.6 + 0.4 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  final Color color;
  const _DotGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 22.0;
    for (double y = 0; y < size.height; y += spacing) {
      for (double x = 0; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => oldDelegate.color != color;
}

/// Image bubble content: a rounded thumbnail that opens a pinch-to-zoom
/// full-screen viewer on tap. [path] is always a LOCAL file path — either
/// the sender's own compressed copy, or the copy the recipient's device
/// already downloaded, decrypted, and saved (see
/// MessageRelayService._receiveMediaMessage). Nothing here ever talks to
/// Supabase directly; by the time a message exists in the local store, its
/// media is already sitting on this device.
/// Feature: upload progress + retry queue. Replaces the old plain
/// "always show a check-mark icon" status row so 'sending' shows live
/// progress and 'failed' shows a tappable retry affordance, instead of
/// both previously being impossible states for this row to represent
/// (media messages used to only ever appear in the chat AFTER a
/// successful upload — see MessageRelayService.sendMediaMessage).
class _StatusIndicator extends StatelessWidget {
  final String id;
  final String status;
  final bool isMine;
  final VoidCallback onRetry;
  const _StatusIndicator({required this.id, required this.status, required this.isMine, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = isMine ? scheme.onPrimary : scheme.onSurface;

    if (status == 'sending') {
      return ValueListenableBuilder<double>(
        valueListenable: MediaService.progressNotifierFor(id),
        builder: (context, progress, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6, value: progress > 0 ? progress : null, color: fg.withValues(alpha: 0.85)),
            ),
            const SizedBox(width: 5),
            Text('Sending…', style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.75))),
          ],
        ),
      );
    }
    if (status == 'failed') {
      return InkWell(
        onTap: onRetry,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 13, color: scheme.error),
            const SizedBox(width: 4),
            Text('Tap to retry', style: TextStyle(fontSize: 11, color: scheme.error, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }
    return Icon(
      status == 'read' || status == 'delivered' ? Icons.done_all : Icons.done,
      size: 14,
      color: status == 'read' ? Colors.lightBlueAccent : fg.withValues(alpha: 0.75),
    );
  }
}

/// Feature: view-once media bubble. Three distinct states:
///   - Sent by ME, not yet opened by them: shows the actual thumbnail
///     (I can always see my own send) with a small "1" badge so it's
///     visually distinct from a normal photo/video I sent.
///   - Received, not yet opened: a tappable placeholder — no thumbnail
///     preview at all, matching Signal/WhatsApp (showing a preview would
///     defeat the "view once" privacy promise). Tapping opens
///     ViewOnceMediaScreen, which deletes the file the moment it's closed.
///   - Received AND already opened ([consumed]): a permanent, non-
///     interactive "Opened" placeholder — [path] is null at this point
///     (LocalMessageStore.consumeViewOnce already deleted the file), so
///     there is nothing left to show or tap into.
class _ViewOnceBubbleContent extends StatelessWidget {
  final String id;
  final String? path;
  final bool isVideo;
  final bool isMine;
  final bool consumed;
  const _ViewOnceBubbleContent({
    required this.id,
    required this.path,
    required this.isVideo,
    required this.isMine,
    required this.consumed,
  });

  @override
  Widget build(BuildContext context) {
    if (isMine && path != null) {
      // My own copy is never consumed — show it like a normal bubble,
      // just with a badge marking it as view-once for the other person.
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: isVideo
                ? Container(width: 220, height: 160, color: Colors.black87, alignment: Alignment.center, child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 52))
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240, minWidth: 160),
                    child: Image.file(File(path!), fit: BoxFit.cover),
                  ),
          ),
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.filter_1, color: Colors.white, size: 12),
                  SizedBox(width: 2),
                  Text('View once', style: TextStyle(color: Colors.white, fontSize: 10)),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (consumed || path == null) {
      return Container(
        width: 200,
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.visibility_off_outlined, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(isVideo ? 'Video · Opened' : 'Photo · Opened', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ViewOnceMediaScreen(messageId: id, path: path!, isVideo: isVideo)),
        );
      },
      child: Container(
        width: 200,
        height: 90,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.remove_red_eye_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer),
            const SizedBox(height: 4),
            Text(
              isVideo ? 'Tap to view video once' : 'Tap to view photo once',
              style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateSeparator extends StatelessWidget {
  final String label;
  const _DateSeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
          child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class _ImageBubbleContent extends StatelessWidget {
  final String path;
  final List<MediaViewerItem> gallery;
  final int galleryIndex;
  const _ImageBubbleContent({required this.path, this.gallery = const [], this.galleryIndex = -1});

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return GestureDetector(
      // Feature: in-app media viewer — opens the shared swipeable gallery
      // (every photo/video in this chat, in order) instead of a
      // single-image page, so the person can keep swiping through shared
      // media without backing out and re-tapping each one. Falls back to
      // just this one image if it's somehow not part of the passed-in
      // gallery list (shouldn't normally happen).
      onTap: () {
        final index = galleryIndex >= 0 ? galleryIndex : 0;
        final items = gallery.isNotEmpty ? gallery : [MediaViewerItem(path: path, isVideo: false)];
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => MediaViewerScreen(items: items, initialIndex: index)));
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, minWidth: 160),
          child: file.existsSync()
              ? Image.file(file, fit: BoxFit.cover)
              : Container(
                  color: Colors.black12,
                  height: 160,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_outlined),
                ),
        ),
      ),
    );
  }
}

/// Video bubble content: a thumbnail with a play overlay. The actual
/// player only loads once opened — building a VideoPlayerController for
/// every video bubble in a long chat history up front would be wasteful.
class _VideoBubbleContent extends StatelessWidget {
  final String path;
  final List<MediaViewerItem> gallery;
  final int galleryIndex;
  const _VideoBubbleContent({required this.path, this.gallery = const [], this.galleryIndex = -1});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final index = galleryIndex >= 0 ? galleryIndex : 0;
        final items = gallery.isNotEmpty ? gallery : [MediaViewerItem(path: path, isVideo: true)];
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => MediaViewerScreen(items: items, initialIndex: index)));
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 220,
          height: 160,
          color: Colors.black87,
          alignment: Alignment.center,
          child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 52),
        ),
      ),
    );
  }
}
