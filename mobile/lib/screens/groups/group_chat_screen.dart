import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/local_message.dart';
import '../../services/group_message_relay_service.dart';
import '../../services/group_service.dart';
import '../../services/local_message_store.dart';
import '../../services/media_compression_service.dart';
import '../../services/media_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/chat_wallpaper_service.dart';
import '../../services/inactivity_wipe_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../services/signal_session_service.dart';
import '../../services/voice_recording_controller.dart';
import '../../widgets/attachment_menu.dart';
import '../../widgets/media_viewer_screen.dart';
import '../../widgets/message_link_text.dart';
import '../../widgets/view_once_media_screen.dart';
import '../../widgets/voice_message_bubble.dart';
import '../../widgets/voice_recording_bar.dart';
import '../chat/chat_search_screen.dart';
import '../security/safety_number_screen.dart';
import 'group_info_screen.dart';

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉', '😍', '👏', '💯', '😡'];

String _mediaLabel(String type) {
  switch (type) {
    case 'image':
      return '📷 Photo';
    case 'video':
      return '🎥 Video';
    case 'voice':
      return '🎤 Voice message';
    default:
      return type;
  }
}

class GroupChatScreen extends StatefulWidget {
  final String groupId;
  const GroupChatScreen({super.key, required this.groupId});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  // Feature: unified voice/media UI (chat + group) — shared controller
  // instead of this screen's own duplicated recording state/logic.
  late final _voiceController = VoiceRecordingController(
    onTick: () => setState(() {}),
    onMaxLengthReached: _stopAndSendVoiceRecording,
  );
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  List<LocalMessage> _messages = [];
  List<String> _memberUids = [];
  final Map<String, String> _usernames = {}; // uid -> username, resolved lazily
  String _groupName = 'Group';
  bool _onlyAdminsCanSend = false;
  bool _amAdmin = false;
  String? _groupAvatarUrl;
  int _ttlHours = 0;
  // Feature: "clear on exit" ephemeral view mode, group version — kept in
  // sync with the group doc, same as _onlyAdminsCanSend right above.
  bool _ephemeralViewEnabled = false;
  LocalMessage? _replyingTo;

  /// Non-null while composing an edit to a previously-sent text message —
  /// mutually exclusive with [_replyingTo]. See _startEditing /
  /// GroupMessageRelayService.editGroupMessage.
  LocalMessage? _editingMessage;

  /// Live @mention suggestions while typing "@partialname" — cleared as
  /// soon as the partial word stops looking like a mention-in-progress
  /// (a space typed after it, the @ deleted, etc). See _onTextChanged.
  List<String> _mentionSuggestions = [];

  bool _sendingMedia = false;

  // Feature: accurate per-member group read receipts — messageId ->
  // {memberUid: 'delivered'|'read'}, kept live via watchGroupReceipts.
  Map<String, Map<String, String>> _receipts = {};

  late final StreamSubscription<List<LocalMessage>> _msgSub;
  late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> _groupSub;
  late final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> _typingSub;
  late final StreamSubscription<Map<String, Map<String, String>>> _receiptSub;
  Set<String> _typingUids = {};

  /// Debounce for the "hasn't updated the app yet" notice (see
  /// _warnAboutPartialFailure) — without this, sending several messages in
  /// a row to a group with one outdated member would pop a fresh snackbar
  /// for every single one, even though nothing actionable changed between
  /// them.
  final Map<String, DateTime> _lastNotUpgradedWarnedAt = {};

  // Feature: anti-tampering / MITM re-verification prompts, group version.
  // Checked per-member (excluding myself) whenever the member list
  // changes, throttled the same way chat_list_screen.dart's entry-level
  // check is.
  final Set<String> _membersWithChangedIdentity = {};
  // Feature: multi-select + bulk actions. Same shape as
  // chat_detail_screen.dart's own _selectedIds — long-press a message to
  // start selecting, tap others to add/remove, a bulk action bar (Copy/
  // Star/Delete) replaces the normal app bar while anything's selected.
  final Set<String> _selectedIds = {};
  final Map<String, GlobalKey> _bubbleKeys = {};
  GlobalKey _bubbleKeyFor(String id) => _bubbleKeys.putIfAbsent(id, () => GlobalKey());
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

  /// Feature: date separators — same logic as chat_detail_screen.dart's
  /// own version of this.
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

  // Feature: "jump to unread" button — same one-shot design as
  // chat_detail_screen.dart's own _firstUnreadId.
  String? _firstUnreadId;
  // Feature: chat wallpapers/themes per conversation.
  ChatWallpaper _wallpaper = kChatWallpapers.first;
  Future<void> _loadWallpaper() async {
    final w = await ChatWallpaperService.getWallpaper(widget.groupId);
    if (mounted) setState(() => _wallpaper = w);
  }
  DateTime? _lastIdentityCheck;

  Future<void> _checkMemberIdentityChanges() async {
    final now = DateTime.now();
    if (_lastIdentityCheck != null && now.difference(_lastIdentityCheck!) < const Duration(seconds: 60)) return;
    _lastIdentityCheck = now;
    final changed = <String>{};
    for (final uid in _memberUids) {
      if (uid == _myUid) continue;
      if (await SignalSessionService.instance.hasUnverifiedIdentityChange(uid)) changed.add(uid);
    }
    if (mounted) setState(() => _membersWithChangedIdentity..clear()..addAll(changed));
  }

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    // Feature: "jump to unread" button. Fired first — best-effort race
    // against markConversationRead below, same reasoning as
    // chat_detail_screen.dart's own version of this.
    LocalMessageStore.getFirstUnreadId(widget.groupId).then((id) {
      if (mounted) setState(() => _firstUnreadId = id);
    });
    _loadWallpaper();
    InactivityWipeService.recordOpened(widget.groupId);
    // Silently flush any messages that were queued because a member
    // hadn't updated the app yet (see ContactNotUpgradedException /
    // retryPendingResends) — opening the group is a natural, frequent
    // catch-up point, on top of the app-startup-wide sweep in main.dart.
    GroupMessageRelayService.retryPendingResends(widget.groupId);
    _textController.addListener(() => setState(() {}));
    _msgSub = LocalMessageStore.watchConversation(widget.groupId).listen((list) {
      if (!mounted) return;
      setState(() => _messages = list);
      _resolveUsernames(list.map((m) => m.senderUid));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      LocalMessageStore.markConversationRead(widget.groupId);
    });
    _groupSub = GroupService.instance.groupStream(widget.groupId).listen((doc) {
      if (!mounted) return;
      final data = doc.data();
      if (data == null) return;
      setState(() {
        _groupName = (data['name'] as String?) ?? 'Group';
        _groupAvatarUrl = data['avatarUrl'] as String?;
        _memberUids = List<String>.from(data['members'] ?? []);
        _ttlHours = (data['chatTtlHours'] as num?)?.toInt() ?? 0;
        // Feature: group security setting — see GroupInfoScreen's "Only
        // admins can send messages" toggle and Group.onlyAdminsCanSend.
        _onlyAdminsCanSend = (data['onlyAdminsCanSend'] as bool?) ?? false;
        _amAdmin = List<String>.from(data['admins'] ?? []).contains(_myUid);
        _ephemeralViewEnabled = (data['ephemeralViewEnabled'] as bool?) ?? false;
      });
      _resolveUsernames(_memberUids);
      _checkMemberIdentityChanges();
    });
    _typingSub = GroupService.instance.typingStream(widget.groupId).listen((snap) {
      if (!mounted) return;
      final me = _myUid;
      setState(() {
        _typingUids = snap.docs
            .where((d) => d.id != me && (d.data()['isTyping'] as bool? ?? false))
            .map((d) => d.id)
            .toSet();
      });
    });
    // Feature: accurate per-member group read receipts.
    _receiptSub = LocalMessageStore.watchGroupReceipts(widget.groupId).listen((m) {
      if (mounted) setState(() => _receipts = m);
    });
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    GroupService.instance.setTyping(widget.groupId, false);
    // Feature: "clear on exit" ephemeral view mode, group version. Fires
    // exactly once, only when THIS member's OWN GroupChatScreen instance
    // for THIS EXACT groupId is actually leaving the widget tree — never
    // on backgrounding the app (which pauses, not disposes, this screen),
    // and never affecting any other group or any other member's device.
    // This is the fix for the failure mode explicitly flagged when this
    // was requested: entering and leaving ONE group must never clear
    // anyone else's chats, and must never clear this group for anyone
    // else — it only ever touches widget.groupId, and only on this one
    // device.
    if (_ephemeralViewEnabled) {
      LocalMessageStore.clearConversation(widget.groupId);
    }
    _msgSub.cancel();
    _groupSub.cancel();
    _typingSub.cancel();
    _receiptSub.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _voiceController.dispose();
    super.dispose();
  }

  Future<void> _resolveUsernames(Iterable<String> uids) async {
    final missing = uids.toSet().where((u) => !_usernames.containsKey(u)).toList();
    if (missing.isEmpty) return;
    final db = FirebaseFirestore.instance;
    for (final uid in missing) {
      final doc = await db.collection('users').doc(uid).get();
      _usernames[uid] = (doc.data()?['username'] as String?) ?? 'Unknown';
    }
    if (mounted) setState(() {});
  }

  String _nameFor(String uid) => uid == _myUid ? 'You' : (_usernames[uid] ?? '…');

  /// Feature: anti-tampering / MITM re-verification prompts, group
  /// version. Same no-silent-dismiss shape as the 1:1 banner — each
  /// affected member gets a row with Verify (safety number screen) and
  /// Trust (re-pin) actions, since a group's whole membership can't be
  /// resolved with one tap the way a single 1:1 banner can.
  Widget _buildIdentityChangeBanner(ColorScheme scheme) {
    final count = _membersWithChangedIdentity.length;
    return Material(
      color: scheme.errorContainer,
      child: InkWell(
        onTap: () => _showIdentityChangeDialog(scheme),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.gpp_maybe_outlined, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  count == 1
                      ? "${_nameFor(_membersWithChangedIdentity.first)}'s security code changed"
                      : "$count members' security codes changed",
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

  void _showIdentityChangeDialog(ColorScheme scheme) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Security codes changed'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: _membersWithChangedIdentity.map((uid) {
              return ListTile(
                title: Text(_nameFor(uid)),
                subtitle: const Text('Verify or trust the new code'),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => SafetyNumberScreen(peerUid: uid, peerUsername: _nameFor(uid))),
                        );
                      },
                      child: const Text('Verify'),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          await SignalSessionService.instance.acceptChangedIdentityAndRetry(uid);
                          if (mounted) setState(() => _membersWithChangedIdentity.remove(uid));
                          if (dialogContext.mounted) Navigator.pop(dialogContext);
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Couldn't confirm the new key — please try again.")),
                            );
                          }
                        }
                      },
                      child: const Text('Trust'),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
      ),
    );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _onTextChanged(String value) {
    GroupService.instance.setTyping(widget.groupId, value.trim().isNotEmpty);
    _updateMentionSuggestions();
  }

  /// Looks at the text immediately before the cursor for an unfinished
  /// "@partialname" and, if found, narrows [_mentionSuggestions] to other
  /// members whose username starts with that partial text. Cleared
  /// whenever what's before the cursor doesn't look like an in-progress
  /// mention (no trailing @word, or a space/newline right after the @).
  void _updateMentionSuggestions() {
    final text = _textController.text;
    final cursor = _textController.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) {
      if (_mentionSuggestions.isNotEmpty) setState(() => _mentionSuggestions = []);
      return;
    }
    final before = text.substring(0, cursor);
    final match = RegExp(r'(?:^|\s)@([\w]*)$').firstMatch(before);
    if (match == null) {
      if (_mentionSuggestions.isNotEmpty) setState(() => _mentionSuggestions = []);
      return;
    }
    final partial = match.group(1)!.toLowerCase();
    final matches = _otherMembers
        .map((uid) => _usernames[uid])
        .whereType<String>()
        .where((name) => name.toLowerCase().startsWith(partial))
        .take(5)
        .toList();
    setState(() => _mentionSuggestions = matches);
  }

  /// Replaces the in-progress "@partial" the person just typed with the
  /// chosen "@username " — same UX as tapping a suggestion in any other
  /// mention-aware chat app.
  void _applyMention(String username) {
    final text = _textController.text;
    final cursor = _textController.selection.baseOffset;
    final before = cursor >= 0 && cursor <= text.length ? text.substring(0, cursor) : text;
    final after = cursor >= 0 && cursor <= text.length ? text.substring(cursor) : '';
    final match = RegExp(r'(?:^|\s)@([\w]*)$').firstMatch(before);
    if (match == null) return;
    final start = match.start + (match.group(0)!.startsWith(' ') ? 1 : 0);
    final newBefore = '${before.substring(0, start)}@$username ';
    _textController.value = TextEditingValue(
      text: newBefore + after,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );
    setState(() => _mentionSuggestions = []);
  }

  List<String> get _otherMembers => _memberUids.where((u) => u != _myUid).toList();

  /// [resendText]/[resendReplyToId] are only passed for a TEXT message
  /// send failure — see GroupMessageRelayService.resendTextMessage's own
  /// doc comment for why media failures don't offer this action. When
  /// present, the snackbar gets a "Resend to X" action that retries
  /// delivery to just the members who were missed, closing the loop
  /// instead of leaving the warning as the only trace of the failure.
  ///
  /// BUGFIX: a member who simply hasn't updated the app yet
  /// (ContactNotUpgradedException) used to get the exact same "Resend to
  /// X" treatment as any other failure — meaning sending several messages
  /// in a row to a group with one outdated member popped a fresh "Resend"
  /// snackbar for every single one, even though tapping Resend would just
  /// fail again for the identical reason every time (nothing changes
  /// until THEY update). That specific case is now split out: it's
  /// already been silently queued for automatic delivery (see
  /// GroupMessageRelayService.retryPendingResends, called on group open
  /// and at app startup), so this just shows a one-time-per-cooldown,
  /// non-actionable heads up instead of repeating the same dead-end
  /// prompt. Any OTHER kind of failure (network blip, momentarily-
  /// exhausted prekey pool) keeps the original immediate, actionable
  /// "Resend to X" behavior, since an instant retry can genuinely help there.
  Future<void> _warnAboutPartialFailure(
    GroupSendPartialFailure e, {
    String? resendText,
    String? resendReplyToId,
  }) async {
    await _resolveUsernames(e.failures.map((f) => f.uid));
    if (!mounted) return;

    // A rate-limit hit fails EVERY member's row identically (they all
    // share one client_id — see the migration's distinct-client_id
    // counting), so this always shows up as "every member failed for
    // the same reason," never a mix. Show the one friendly message
    // instead of a contact-key-sounding "didn't reach: everyone."
    if (e.failures.isNotEmpty && e.failures.every((f) => f.error is RateLimitedException)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text((e.failures.first.error as RateLimitedException).message)),
      );
      return;
    }

    final notUpgraded = e.failures.where((f) => f.error is ContactNotUpgradedException).toList();
    final other = e.failures.where((f) => f.error is! ContactNotUpgradedException).toList();

    if (other.isNotEmpty) {
      final names = other.map((f) => _nameFor(f.uid)).join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Didn't reach: $names — they may need to reopen the app once."),
          duration: const Duration(seconds: 8),
          action: resendText == null
              ? null
              : SnackBarAction(
                  label: other.length == 1 ? 'Resend to $names' : 'Resend to ${other.length}',
                  onPressed: () => _resendToFailedMembers(
                    GroupSendPartialFailure(e.clientId, other),
                    resendText,
                    resendReplyToId,
                  ),
                ),
        ),
      );
    }

    final now = DateTime.now();
    final freshlyNotUpgraded = notUpgraded.where((f) {
      final last = _lastNotUpgradedWarnedAt[f.uid];
      return last == null || now.difference(last) > const Duration(minutes: 10);
    }).toList();
    if (freshlyNotUpgraded.isNotEmpty) {
      for (final f in freshlyNotUpgraded) {
        _lastNotUpgradedWarnedAt[f.uid] = now;
      }
      final names = freshlyNotUpgraded.map((f) => _nameFor(f.uid)).join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("$names hasn't updated the app yet — they'll get this once they do."),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// Retries delivering the same already-sent message to just the members
  /// who were missed the first time — the "Resend to X" snackbar action.
  Future<void> _resendToFailedMembers(GroupSendPartialFailure original, String text, String? replyToId) async {
    final retryFailures = await GroupMessageRelayService.resendTextMessage(
      groupId: widget.groupId,
      uids: original.failures.map((f) => f.uid).toList(),
      clientId: original.clientId,
      text: text,
      replyToId: replyToId,
      ttlHours: _ttlHours,
    );
    if (!mounted) return;
    if (retryFailures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Resent successfully.')));
    } else {
      await _warnAboutPartialFailure(
        GroupSendPartialFailure(original.clientId, retryFailures),
        resendText: text,
        resendReplyToId: replyToId,
      );
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("You're not signed in. Please sign in again.")));
      return;
    }

    final editing = _editingMessage;
    if (editing != null) {
      _textController.clear();
      setState(() {
        _editingMessage = null;
        _mentionSuggestions = [];
      });
      try {
        await GroupMessageRelayService.editGroupMessage(
          groupId: widget.groupId,
          memberUids: _otherMembers,
          messageId: editing.id,
          newText: text,
          originalCreatedAt: editing.createdAt,
        );
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
    final replyId = _replyingTo?.id;
    setState(() {
      _replyingTo = null;
      _mentionSuggestions = [];
    });
    try {
      await GroupMessageRelayService.sendGroupMessage(
        groupId: widget.groupId,
        memberUids: _otherMembers,
        text: text,
        replyToId: replyId,
        ttlHours: _ttlHours,
      );
    } on GroupSendPartialFailure catch (e) {
      await _warnAboutPartialFailure(e, resendText: text, resendReplyToId: replyId);
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $e')));
    }
    await GroupService.instance.setTyping(widget.groupId, false);
  }

  /// Entry point for the "Edit" action in _showMessageActions — only
  /// offered there for a message that is ours, is plain text, and is
  /// still inside GroupMessageRelayService.editWindow.
  void _startEditing(LocalMessage message) {
    setState(() {
      _editingMessage = message;
      _replyingTo = null;
      _textController.text = message.text;
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
      MaterialPageRoute(builder: (_) => ChatSearchScreen(conversationId: widget.groupId, peerUsername: _groupName)),
    );
    if (targetId == null || !mounted) return;
    _jumpToMessage(targetId);
  }

  void _showAttachSheet() {
    showAttachmentMenu(
      context,
      onCameraPhoto: () => _pickAndSendImage(ImageSource.camera),
      onGalleryPhoto: () => _pickAndSendImage(ImageSource.gallery),
      onCameraVideo: () => _pickAndSendVideo(ImageSource.camera),
      onGalleryVideo: () => _pickAndSendVideo(ImageSource.gallery),
      onCameraPhotoViewOnce: () => _pickAndSendImage(ImageSource.camera, viewOnce: true),
      onGalleryPhotoViewOnce: () => _pickAndSendImage(ImageSource.gallery, viewOnce: true),
      onCameraVideoViewOnce: () => _pickAndSendVideo(ImageSource.camera, viewOnce: true),
      onGalleryVideoViewOnce: () => _pickAndSendVideo(ImageSource.gallery, viewOnce: true),
    );
  }

  Future<void> _pickAndSendImage(ImageSource source, {bool viewOnce = false}) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 100);
    if (picked == null) return;
    await _sendMedia(
      file: File(picked.path),
      messageType: 'image',
      mime: 'image/jpeg',
      extension: 'jpg',
      compress: (file) => MediaCompressionService.compressImage(file),
      viewOnce: viewOnce,
    );
  }

  Future<void> _pickAndSendVideo(ImageSource source, {bool viewOnce = false}) async {
    final picked = await ImagePicker().pickVideo(source: source, maxDuration: const Duration(minutes: 2));
    if (picked == null) return;
    await _sendMedia(
      file: File(picked.path),
      messageType: 'video',
      mime: 'video/mp4',
      extension: 'mp4',
      compress: (file) async => (await MediaCompressionService.compressVideo(file)).readAsBytesSync(),
      viewOnce: viewOnce,
    );
  }

  Future<void> _sendMedia({
    required File file,
    required String messageType,
    required String mime,
    required String extension,
    required Future<List<int>> Function(File) compress,
    int? durationMs,
    bool viewOnce = false,
  }) async {
    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("You're not signed in. Please sign in again.")));
      return;
    }
    setState(() => _sendingMedia = true);
    try {
      final bytes = await compress(file);
      await GroupMessageRelayService.sendGroupMediaMessage(
        groupId: widget.groupId,
        memberUids: _otherMembers,
        plainBytes: bytes,
        messageType: messageType,
        extension: extension,
        mime: mime,
        durationMs: durationMs,
        ttlHours: _ttlHours,
        isViewOnce: viewOnce,
      );
    } on GroupSendPartialFailure catch (e) {
      await _warnAboutPartialFailure(e);
    } on MediaTooLargeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $e')));
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  Future<void> _startVoiceRecording() async {
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
    await _sendMedia(
      file: file,
      messageType: 'voice',
      mime: 'audio/mp4',
      extension: 'm4a',
      durationMs: durationMs,
      compress: (f) async => f.readAsBytesSync(), // already recorded at a low speech bitrate, no post-compression needed
    );
  }

  /// Retries a photo/video/voice message that failed to send (status
  /// 'failed' — see GroupMessageRelayService.sendGroupMediaMessage/
  /// retryMediaMessage). Tapped from the bubble's own "Tap to retry" row.
  Future<void> _retryMediaSend(String clientId) async {
    try {
      await GroupMessageRelayService.retryMediaMessage(clientId);
    } on GroupSendPartialFailure catch (e) {
      if (mounted) _warnAboutPartialFailure(e);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Still couldn\'t send — $e')));
    }
  }

  Future<void> _react(LocalMessage message, String emoji) async {
    final myUid = _myUid;
    if (myUid == null) return;
    final mine = message.reactions[myUid];
    final next = mine == emoji ? null : emoji;
    await LocalMessageStore.setReaction(message.id, myUid, next);
    await GroupMessageRelayService.sendReaction(
      groupId: widget.groupId,
      memberUids: _memberUids,
      messageId: message.id,
      emoji: next,
    );
  }

  void _showMessageActions(LocalMessage message) {
    final mine = message.isMine;
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            SizedBox(
              height: 52,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: _quickReactions.map((e) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _react(message, e);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() => _replyingTo = message);
              },
            ),
            ListTile(
              leading: Icon(message.starred ? Icons.star : Icons.star_border),
              title: Text(message.starred ? 'Unstar' : 'Star'),
              onTap: () {
                Navigator.pop(sheetContext);
                LocalMessageStore.toggleStar(message.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Select'),
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() => _selectedIds.add(message.id));
              },
            ),
            if (message.messageType == 'text')
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Clipboard.setData(ClipboardData(text: message.text));
                },
              ),
            if (mine &&
                message.messageType == 'text' &&
                DateTime.now().difference(message.createdAt) <= GroupMessageRelayService.editWindow)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _startEditing(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.pop(sheetContext);
                GroupMessageRelayService.deleteForMe(message.id);
              },
            ),
            if (mine)
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
                title: Text('Delete for everyone', style: TextStyle(color: scheme.error)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  GroupMessageRelayService.deleteForEveryone(
                    groupId: widget.groupId,
                    memberUids: _memberUids,
                    messageId: message.id,
                  );
                },
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  LocalMessage? _findMessage(String? id) {
    if (id == null) return null;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  Widget _replyPreviewChip(LocalMessage target, bool mine, ColorScheme scheme) {
    final accent = mine ? scheme.onPrimary : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_nameFor(target.senderUid), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: accent)),
          Text(
            target.messageType == 'text' ? target.text : _mediaLabel(target.messageType),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: (mine ? scheme.onPrimary : scheme.onSurfaceVariant).withValues(alpha: 0.9)),
          ),
        ],
      ),
    );
  }

  Widget _reactionsPill(LocalMessage message, ColorScheme scheme, bool mine) {
    final counts = <String, int>{};
    for (final e in message.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final accent = mine ? scheme.onPrimary : scheme.primary;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: counts.entries.map((entry) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(entry.key, style: const TextStyle(fontSize: 12)),
              if (entry.value > 1) ...[
                const SizedBox(width: 3),
                Text('${entry.value}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: accent)),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }

  /// Feature: upload progress + retry queue, and accurate per-member
  /// group read receipts. Shown only under the sender's OWN messages —
  /// 'sending'/'failed' come from the shared `status` column (set by
  /// GroupMessageRelayService.sendGroupMediaMessage/retryMediaMessage);
  /// once a message is actually sent, this switches to a real "Read X/Y"
  /// count from [_receipts] instead of a single check mark that could
  /// only ever reflect whichever member's receipt arrived last.
  Widget _statusRow(LocalMessage message, ColorScheme scheme) {
    final fg = scheme.onPrimary;
    if (message.status == 'sending') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: ValueListenableBuilder<double>(
            valueListenable: MediaService.progressNotifierFor(message.id),
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
          ),
        ),
      );
    }
    if (message.status == 'failed') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: InkWell(
            onTap: () => _retryMediaSend(message.id),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 13, color: scheme.error),
                const SizedBox(width: 4),
                Text('Tap to retry', style: TextStyle(fontSize: 11, color: scheme.error, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );
    }

    final total = _otherMembers.length;
    if (total == 0) return const SizedBox.shrink();
    final statuses = _receipts[message.id] ?? const {};
    final readCount = statuses.values.where((s) => s == 'read').length;
    final deliveredCount = statuses.values.where((s) => s == 'read' || s == 'delivered').length;
    final label = readCount == total
        ? 'Read by all'
        : readCount > 0
            ? 'Read $readCount/$total'
            : deliveredCount > 0
                ? 'Delivered $deliveredCount/$total'
                : 'Sent';
    final color = readCount == total ? Colors.lightBlueAccent : fg.withValues(alpha: 0.75);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, size: 13, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }

  /// Feature: message timestamps with seconds — shown on the bottom-right
  /// corner of EVERY bubble (sent and received), same as the 1:1 chat
  /// screen. Formatted by hand rather than via intl DateFormat, to avoid
  /// pulling in a locale/formatting dependency for something this simple.
  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Widget _bubbleFor(LocalMessage message) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isMine;
    final replyTarget = _findMessage(message.replyToId);
    final showsHeader = !mine || replyTarget != null;
    final isMedia = message.messageType == 'image' || message.messageType == 'video';

    // Feature: in-app media viewer — every photo/video in this group chat,
    // in order, so tapping one opens a swipeable gallery instead of a
    // single image/video page. View-once media is deliberately excluded
    // (see the isViewOnce check below) — it isn't part of the browsable
    // shared gallery, the same reasoning as chat_detail_screen.dart.
    final galleryMessages = _messages.where((m) => m.mediaPath != null && !m.isViewOnce && (m.messageType == 'image' || m.messageType == 'video')).toList();
    final gallery = galleryMessages.map((m) => MediaViewerItem(path: m.mediaPath!, isVideo: m.messageType == 'video')).toList();
    final galleryIndex = galleryMessages.indexWhere((m) => m.id == message.id);

    Widget? mediaWidget;
    if (message.messageType == 'image' && message.isViewOnce) {
      mediaWidget = _ViewOnceBubble(id: message.id, path: message.mediaPath, isVideo: false, isMine: mine, consumed: message.viewOnceConsumed);
    } else if (message.messageType == 'video' && message.isViewOnce) {
      mediaWidget = _ViewOnceBubble(id: message.id, path: message.mediaPath, isVideo: true, isMine: mine, consumed: message.viewOnceConsumed);
    } else if (message.messageType == 'image') {
      mediaWidget = message.hasPendingMedia
          ? _pendingMediaTile(scheme, message.id, isVideo: false)
          : message.mediaPath == null
              ? _brokenMediaTile(scheme, 'Photo unavailable')
              : _ImageBubble(path: message.mediaPath!, gallery: gallery, galleryIndex: galleryIndex);
    } else if (message.messageType == 'video') {
      mediaWidget = message.hasPendingMedia
          ? _pendingMediaTile(scheme, message.id, isVideo: true)
          : message.mediaPath == null
              ? _brokenMediaTile(scheme, 'Video unavailable')
              : _VideoBubble(path: message.mediaPath!, gallery: gallery, galleryIndex: galleryIndex);
    }

    // Full theme rebuild, 2026-09-12 — bubbles get a subtle gradient
    // instead of a flat fill (adds real depth without shouting for
    // attention), a touch more corner rounding for a softer/friendlier
    // shape, and a slightly more present shadow so bubbles read as
    // sitting just above the background instead of flat against it.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
      bottomLeft: Radius.circular(mine ? 20 : 5),
      bottomRight: Radius.circular(mine ? 5 : 20),
    );
    final bubbleGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: mine
          ? [scheme.primary, Color.lerp(scheme.primary, Colors.black, 0.12)!]
          : [scheme.surfaceContainerHigh, scheme.surfaceContainerHighest],
    );

    return GestureDetector(
      onLongPress: () {
        if (_selectedIds.isEmpty) {
          setState(() => _selectedIds.add(message.id));
        } else {
          _toggleSelect(message.id);
        }
      },
      onTap: _selectedIds.isNotEmpty ? () => _toggleSelect(message.id) : null,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: bubbleGradient,
            borderRadius: radius,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))],
            border: _selectedIds.contains(message.id) ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showsHeader)
                Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, mediaWidget != null ? 6 : 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!mine)
                        Padding(
                          padding: EdgeInsets.only(bottom: replyTarget != null ? 4 : 0),
                          child: Text(_nameFor(message.senderUid), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
                        ),
                      if (replyTarget != null) _replyPreviewChip(replyTarget, mine, scheme),
                    ],
                  ),
                ),
              if (mediaWidget != null) mediaWidget,
              if (message.messageType == 'voice')
                Padding(
                  padding: EdgeInsets.fromLTRB(10, showsHeader ? 0 : 8, 14, 8),
                  child: message.mediaPath == null
                      ? Text('Voice message unavailable', style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface))
                      : VoiceMessageBubble(path: message.mediaPath!, isMine: mine),
                ),
              if (message.messageType == 'text' || (isMedia && message.text.isNotEmpty))
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    (mediaWidget != null) ? 8 : (showsHeader ? 0 : 8),
                    12,
                    message.reactions.isEmpty ? 8 : 2,
                  ),
                  child: _messageText(message, mine, scheme),
                ),
              if (message.reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: _reactionsPill(message, scheme, mine),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Feature: starred/saved messages — same persistent
                      // bubble indicator as chat_detail_screen.dart's 1:1
                      // version, so it's recognizable at a glance here too.
                      if (message.starred) ...[
                        Icon(Icons.star, size: 11, color: mine ? scheme.onPrimary.withValues(alpha: 0.8) : Colors.amber),
                        const SizedBox(width: 3),
                      ],
                      Text(
                        _formatTimestamp(message.createdAt),
                        style: TextStyle(fontSize: 10, color: (mine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: 0.6)),
                      ),
                    ],
                  ),
                ),
              ),
              if (mine) _statusRow(message, scheme),
            ],
          ),
        ),
      ),
    );
  }

  /// Renders a message's text with any "@username" substrings that match
  /// a real current member highlighted in bold — the natural next step
  /// from already showing sender names on bubbles (see [_nameFor]). Only
  /// highlights mentions of members actually in this group right now, so
  /// a literal "@" in normal conversation that doesn't match anyone isn't
  /// mistakenly styled as a mention. Also appends a small "(edited)" tag
  /// when the message has been edited (see GroupMessageRelayService.
  /// editGroupMessage).
  Widget _messageText(LocalMessage message, bool mine, ColorScheme scheme) {
    final baseColor = mine ? scheme.onPrimary : scheme.onSurface;
    final baseStyle = TextStyle(color: baseColor, fontSize: 15, height: 1.3);
    final knownNames = _usernames.values.toSet();
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'@([\w]+)');
    var lastEnd = 0;
    for (final match in pattern.allMatches(message.text)) {
      final name = match.group(1)!;
      if (!knownNames.any((n) => n.toLowerCase() == name.toLowerCase())) continue;
      if (match.start > lastEnd) {
        spans.addAll(linkifySpan(context, message.text.substring(lastEnd, match.start), baseStyle, linkColor: mine ? scheme.onPrimary : scheme.primary));
      }
      spans.add(TextSpan(
        text: match.group(0),
        style: TextStyle(fontWeight: FontWeight.w700, color: mine ? scheme.onPrimary : scheme.primary),
      ));
      lastEnd = match.end;
    }
    if (lastEnd < message.text.length) {
      spans.addAll(linkifySpan(context, message.text.substring(lastEnd), baseStyle, linkColor: mine ? scheme.onPrimary : scheme.primary));
    }
    if (message.editedAt != null) {
      spans.add(TextSpan(
        text: '  (edited)',
        style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: baseColor.withValues(alpha: 0.65)),
      ));
    }
    return RichText(text: TextSpan(style: baseStyle, children: spans));
  }

  Widget _brokenMediaTile(ColorScheme scheme, String label) {
    return Container(
      height: 140,
      alignment: Alignment.center,
      color: scheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  // Group security setting: media auto-download restrictions. Tracks
  // which pending-media messages currently have a manual download in
  // flight, purely so the tile can show a spinner instead of being
  // tappable again mid-download.
  final Set<String> _downloadingMediaIds = {};

  Widget _pendingMediaTile(ColorScheme scheme, String messageId, {required bool isVideo}) {
    final downloading = _downloadingMediaIds.contains(messageId);
    return InkWell(
      onTap: downloading
          ? null
          : () async {
              setState(() => _downloadingMediaIds.add(messageId));
              try {
                await MessageRelayService.downloadPendingMedia(messageId);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not download: $e')));
                }
              } finally {
                if (mounted) setState(() => _downloadingMediaIds.remove(messageId));
              }
            },
      child: Container(
        height: 140,
        alignment: Alignment.center,
        color: scheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (downloading)
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(isVideo ? Icons.videocam_outlined : Icons.image_outlined, color: scheme.onSurfaceVariant, size: 28),
            const SizedBox(height: 6),
            Text(
              downloading ? 'Downloading…' : 'Tap to download ${isVideo ? 'video' : 'photo'}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
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

  /// Feature: multi-select + bulk actions, group version. Copy/Star work
  /// for any number selected; Delete only offers "delete for me" in bulk
  /// (matching the per-message menu's own split between "for me" and
  /// "for everyone" — bulk "for everyone" isn't offered here to avoid a
  /// single tap wiping a large batch of messages for the whole group at
  /// once without individually confirming each one).
  AppBar _buildSelectionAppBar(ColorScheme scheme) {
    final selected = _messages.where((m) => _selectedIds.contains(m.id)).toList();
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selectedIds.clear)),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy_outlined),
          tooltip: 'Copy',
          onPressed: () {
            final ordered = List<LocalMessage>.from(selected)..sort((a, b) => a.createdAt.compareTo(b.createdAt));
            Clipboard.setData(ClipboardData(text: ordered.map((m) => m.text).join('\n')));
            setState(_selectedIds.clear);
          },
        ),
        IconButton(
          icon: Icon(selected.every((m) => m.starred) ? Icons.star : Icons.star_border),
          tooltip: 'Star',
          onPressed: () async {
            await LocalMessageStore.setStarredBulk(_selectedIds.toList(), !selected.every((m) => m.starred));
            if (mounted) setState(_selectedIds.clear);
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete for me',
          onPressed: () async {
            for (final id in _selectedIds.toList()) {
              await GroupMessageRelayService.deleteForMe(id);
            }
            if (mounted) setState(_selectedIds.clear);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: _selectedIds.isNotEmpty
          ? _buildSelectionAppBar(scheme)
          : AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupInfoScreen(groupId: widget.groupId))).then((_) => _loadWallpaper()),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                backgroundImage: _groupAvatarUrl != null ? NetworkImage(_groupAvatarUrl!) : null,
                child: _groupAvatarUrl == null ? const Icon(Icons.groups_rounded, size: 18) : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_groupName, overflow: TextOverflow.ellipsis),
                    Text(
                      _typingUids.isNotEmpty ? '${_typingUids.map(_nameFor).join(', ')} typing…' : '${_memberUids.length} members',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search), tooltip: 'Search in chat', onPressed: _openSearch),
        ],
      ),
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
      body: Container(
        decoration: BoxDecoration(
          color: _wallpaper.colors.length == 1 ? _wallpaper.colors.first : null,
          gradient: _wallpaper.colors.length > 1 ? LinearGradient(colors: _wallpaper.colors, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        ),
        child: Column(
        children: [
          if (_membersWithChangedIdentity.isNotEmpty) _buildIdentityChangeBanner(scheme),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.groups_rounded, size: 56, color: scheme.primary.withValues(alpha: 0.4)),
                          const SizedBox(height: 12),
                          Text('No messages yet — say hi 👋', style: TextStyle(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final bubble = KeyedSubtree(key: _bubbleKeyFor(_messages[i].id), child: _bubbleFor(_messages[i]));
                      final showDateHeader = i == 0 || !_isSameDay(_messages[i - 1].createdAt, _messages[i].createdAt);
                      if (!showDateHeader) return bubble;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [_DateSeparator(label: _formatDateSeparator(_messages[i].createdAt)), bubble],
                      );
                    },
                  ),
          ),
          if (_editingMessage != null)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Editing message', maxLines: 1, overflow: TextOverflow.ellipsis)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _cancelEdit,
                  ),
                ],
              ),
            )
          else if (_replyingTo != null)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border(left: BorderSide(color: scheme.primary, width: 3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Replying to ${_nameFor(_replyingTo!.senderUid)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
                        Text(
                          _replyingTo!.messageType == 'text' ? _replyingTo!.text : _mediaLabel(_replyingTo!.messageType),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ],
              ),
            ),
          if (_mentionSuggestions.isNotEmpty)
            Container(
              height: 44,
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _mentionSuggestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final name = _mentionSuggestions[i];
                  return ActionChip(
                    avatar: const Icon(Icons.alternate_email, size: 15),
                    label: Text(name),
                    onPressed: () => _applyMention(name),
                  );
                },
              ),
            ),
          SafeArea(
            top: false,
            child: _voiceController.isRecording
                ? VoiceRecordingBar(
                    seconds: _voiceController.seconds,
                    onCancel: _cancelVoiceRecording,
                    onSend: _stopAndSendVoiceRecording,
                  )
                : (_onlyAdminsCanSend && !_amAdmin)
                    ? _buildAdminsOnlyNotice(scheme)
                    : _buildComposeBar(scheme),
          ),
        ],
      ),
    );
  }

  /// Feature: group security setting — shown instead of the normal
  /// compose bar for a non-admin member when GroupInfoScreen's "Only
  /// admins can send messages" toggle is on. Everyone can still read and
  /// react to messages as normal; only sending is restricted.
  Widget _buildAdminsOnlyNotice(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(Icons.campaign_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Only admins can send messages in this group',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposeBar(ColorScheme scheme) {
    final hasText = _textController.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(26)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: Icon(Icons.attach_file_outlined, color: scheme.onSurfaceVariant),
                    onPressed: _sendingMedia ? null : _showAttachSheet,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 12, right: 8),
                      child: TextField(
                        controller: _textController,
                        onChanged: _onTextChanged,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          isCollapsed: true,
                          filled: false,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sendingMedia
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary)),
                )
              : Material(
                  color: scheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: (hasText || _editingMessage != null) ? _send : _startVoiceRecording,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(
                        _editingMessage != null ? Icons.check_rounded : (hasText ? Icons.send_rounded : Icons.mic_rounded),
                        color: scheme.onPrimary,
                        size: 22,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

// ---- inline media bubble widgets — kept local to this screen since the
// equivalents in chat_detail_screen.dart are library-private to that file --
// These render edge-to-edge inside the parent bubble's own rounded/clipped
// Container (see _bubbleFor) — they deliberately have NO rounding or
// padding of their own, so there's only ever one border radius per bubble
// instead of a visible "ring" between an inner and outer radius.

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

class _ViewOnceBubble extends StatelessWidget {
  final String id;
  final String? path;
  final bool isVideo;
  final bool isMine;
  final bool consumed;
  const _ViewOnceBubble({required this.id, required this.path, required this.isVideo, required this.isMine, required this.consumed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (isMine && path != null) {
      return Stack(
        children: [
          SizedBox(
            width: double.infinity,
            height: isVideo ? 200 : 220,
            child: isVideo
                ? Container(color: Colors.black87, alignment: Alignment.center, child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 52))
                : Image.file(File(path!), fit: BoxFit.cover),
          ),
          Positioned(
            top: 8,
            left: 8,
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
        height: 60,
        width: double.infinity,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        color: scheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(Icons.visibility_off_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(isVideo ? 'Video · Opened' : 'Photo · Opened', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return InkWell(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => ViewOnceMediaScreen(messageId: id, path: path!, isVideo: isVideo)));
      },
      child: Container(
        height: 90,
        width: double.infinity,
        alignment: Alignment.center,
        color: scheme.primaryContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.remove_red_eye_outlined, color: scheme.onPrimaryContainer),
            const SizedBox(height: 4),
            Text(isVideo ? 'Tap to view video once' : 'Tap to view photo once', style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ImageBubble extends StatelessWidget {
  final String path;
  final List<MediaViewerItem> gallery;
  final int galleryIndex;
  const _ImageBubble({required this.path, this.gallery = const [], this.galleryIndex = -1});
  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return GestureDetector(
      // Feature: in-app media viewer — opens the shared swipeable gallery
      // (every photo/video in this group, in order) with pinch-zoom and a
      // save-to-device option, instead of a single-image page.
      onTap: () {
        final index = galleryIndex >= 0 ? galleryIndex : 0;
        final items = gallery.isNotEmpty ? gallery : [MediaViewerItem(path: path, isVideo: false)];
        Navigator.push(context, MaterialPageRoute(builder: (_) => MediaViewerScreen(items: items, initialIndex: index)));
      },
      child: SizedBox(
        width: double.infinity,
        height: 220,
        child: file.existsSync()
            ? Image.file(file, fit: BoxFit.cover)
            : Container(color: Colors.black12, alignment: Alignment.center, child: const Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}

class _VideoBubble extends StatelessWidget {
  final String path;
  final List<MediaViewerItem> gallery;
  final int galleryIndex;
  const _VideoBubble({required this.path, this.gallery = const [], this.galleryIndex = -1});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final index = galleryIndex >= 0 ? galleryIndex : 0;
        final items = gallery.isNotEmpty ? gallery : [MediaViewerItem(path: path, isVideo: true)];
        Navigator.push(context, MaterialPageRoute(builder: (_) => MediaViewerScreen(items: items, initialIndex: index)));
      },
      child: SizedBox(
        width: double.infinity,
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black87),
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
