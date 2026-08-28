import 'dart:async';
import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../../models/local_message.dart';
import '../../services/group_message_relay_service.dart';
import '../../services/group_service.dart';
import '../../services/local_message_store.dart';
import '../../services/media_compression_service.dart';
import '../../services/message_relay_service.dart' show NotSignedInException;
import '../../services/screenshot_guard_service.dart';
import '../chat/chat_search_screen.dart';
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

String _fmtSeconds(int totalSeconds) {
  final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
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
  final _voiceRecorder = AudioRecorder();
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  List<LocalMessage> _messages = [];
  List<String> _memberUids = [];
  final Map<String, String> _usernames = {}; // uid -> username, resolved lazily
  String _groupName = 'Group';
  String? _groupAvatarUrl;
  int _ttlHours = 0;
  LocalMessage? _replyingTo;

  /// Non-null while composing an edit to a previously-sent text message —
  /// mutually exclusive with [_replyingTo]. See _startEditing /
  /// GroupMessageRelayService.editGroupMessage.
  LocalMessage? _editingMessage;

  /// Live @mention suggestions while typing "@partialname" — cleared as
  /// soon as the partial word stops looking like a mention-in-progress
  /// (a space typed after it, the @ deleted, etc). See _onTextChanged.
  List<String> _mentionSuggestions = [];

  bool _isRecordingVoice = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  String? _recordingPath;
  bool _sendingMedia = false;
  static const _maxVoiceSeconds = 300;

  late final StreamSubscription<List<LocalMessage>> _msgSub;
  late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> _groupSub;
  late final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> _typingSub;
  Set<String> _typingUids = {};

  /// Debounce for the "hasn't updated the app yet" notice (see
  /// _warnAboutPartialFailure) — without this, sending several messages in
  /// a row to a group with one outdated member would pop a fresh snackbar
  /// for every single one, even though nothing actionable changed between
  /// them.
  final Map<String, DateTime> _lastNotUpgradedWarnedAt = {};

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
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
      });
      _resolveUsernames(_memberUids);
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
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    GroupService.instance.setTyping(widget.groupId, false);
    _msgSub.cancel();
    _groupSub.cancel();
    _typingSub.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _recordTimer?.cancel();
    _voiceRecorder.dispose();
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
    if (targetId == null) return;
    // Group messages render in a plain ListView.builder (no per-bubble
    // GlobalKey the way chat_detail_screen keeps one for jump-to-reply) —
    // scrolling exactly to the matched message isn't wired up here, so
    // this at least confirms the match and lets the person scroll
    // manually rather than silently doing nothing.
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Found it — scroll up to find the highlighted result in the chat.')),
    );
  }

  void _showAttachSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndSendImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Choose a photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndSendImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Record a video'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndSendVideo(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose a video'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndSendVideo(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 100);
    if (picked == null) return;
    await _sendMedia(
      file: File(picked.path),
      messageType: 'image',
      mime: 'image/jpeg',
      extension: 'jpg',
      compress: (file) => MediaCompressionService.compressImage(file),
    );
  }

  Future<void> _pickAndSendVideo(ImageSource source) async {
    final picked = await ImagePicker().pickVideo(source: source, maxDuration: const Duration(minutes: 2));
    if (picked == null) return;
    await _sendMedia(
      file: File(picked.path),
      messageType: 'video',
      mime: 'video/mp4',
      extension: 'mp4',
      compress: (file) async => (await MediaCompressionService.compressVideo(file)).readAsBytesSync(),
    );
  }

  Future<void> _sendMedia({
    required File file,
    required String messageType,
    required String mime,
    required String extension,
    required Future<List<int>> Function(File) compress,
    int? durationMs,
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
    if (!await _voiceRecorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is needed to record a voice message.')),
      );
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${const Uuid().v4()}.m4a');
    await _voiceRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    setState(() {
      _isRecordingVoice = true;
      _recordingPath = path;
      _recordSeconds = 0;
    });
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordSeconds++);
      if (_recordSeconds >= _maxVoiceSeconds) _stopAndSendVoiceRecording();
    });
  }

  Future<void> _cancelVoiceRecording() async {
    _recordTimer?.cancel();
    try {
      await _voiceRecorder.stop();
    } catch (_) {}
    final path = _recordingPath;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    setState(() {
      _isRecordingVoice = false;
      _recordingPath = null;
      _recordSeconds = 0;
    });
  }

  Future<void> _stopAndSendVoiceRecording() async {
    _recordTimer?.cancel();
    final durationMs = _recordSeconds * 1000;
    String? path;
    try {
      path = await _voiceRecorder.stop();
    } catch (_) {}
    path ??= _recordingPath;
    setState(() {
      _isRecordingVoice = false;
      _recordingPath = null;
      _recordSeconds = 0;
    });
    if (path == null) return;
    final file = File(path);
    // A recording under ~1 second is almost always an accidental tap.
    if (durationMs < 800) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return;
    }
    await _sendMedia(
      file: file,
      messageType: 'voice',
      mime: 'audio/mp4',
      extension: 'm4a',
      durationMs: durationMs,
      compress: (f) async => f.readAsBytesSync(), // already recorded at a low speech bitrate, no post-compression needed
    );
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

  Widget _bubbleFor(LocalMessage message) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isMine;
    final replyTarget = _findMessage(message.replyToId);
    final showsHeader = !mine || replyTarget != null;
    final isMedia = message.messageType == 'image' || message.messageType == 'video';

    Widget? mediaWidget;
    if (message.messageType == 'image') {
      mediaWidget = message.mediaPath == null
          ? _brokenMediaTile(scheme, 'Photo unavailable')
          : _ImageBubble(path: message.mediaPath!);
    } else if (message.messageType == 'video') {
      mediaWidget = message.mediaPath == null
          ? _brokenMediaTile(scheme, 'Video unavailable')
          : _VideoBubble(path: message.mediaPath!);
    }

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 4),
      bottomRight: Radius.circular(mine ? 4 : 18),
    );

    return GestureDetector(
      onLongPress: () => _showMessageActions(message),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: mine ? scheme.primary : scheme.surfaceContainerHigh,
            borderRadius: radius,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 1))],
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
                      : _VoiceBubble(path: message.mediaPath!, isMine: mine),
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
    final spans = <TextSpan>[];
    final pattern = RegExp(r'@([\w]+)');
    var lastEnd = 0;
    for (final match in pattern.allMatches(message.text)) {
      final name = match.group(1)!;
      if (!knownNames.any((n) => n.toLowerCase() == name.toLowerCase())) continue;
      if (match.start > lastEnd) spans.add(TextSpan(text: message.text.substring(lastEnd, match.start)));
      spans.add(TextSpan(
        text: match.group(0),
        style: TextStyle(fontWeight: FontWeight.w700, color: mine ? scheme.onPrimary : scheme.primary),
      ));
      lastEnd = match.end;
    }
    if (lastEnd < message.text.length) spans.add(TextSpan(text: message.text.substring(lastEnd)));
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupInfoScreen(groupId: widget.groupId))),
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
      body: Column(
        children: [
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
                    itemBuilder: (context, i) => _bubbleFor(_messages[i]),
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
            child: _isRecordingVoice ? _buildRecordingBar(scheme) : _buildComposeBar(scheme),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(26)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
            const SizedBox(width: 8),
            Text('Recording  ${_fmtSeconds(_recordSeconds)}', style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(icon: Icon(Icons.delete_outline, color: scheme.error), onPressed: _cancelVoiceRecording, tooltip: 'Cancel'),
            Material(
              color: scheme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _stopAndSendVoiceRecording,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(Icons.send_rounded, color: scheme.onPrimary, size: 18),
                ),
              ),
            ),
          ],
        ),
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

class _ImageBubble extends StatelessWidget {
  final String path;
  const _ImageBubble({required this.path});
  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _FullscreenImage(path: path))),
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

class _FullscreenImage extends StatelessWidget {
  final String path;
  const _FullscreenImage({required this.path});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(child: InteractiveViewer(minScale: 0.8, maxScale: 5, child: Image.file(File(path)))),
    );
  }
}

class _VideoBubble extends StatelessWidget {
  final String path;
  const _VideoBubble({required this.path});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _FullscreenVideo(path: path))),
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

class _FullscreenVideoState extends State<_FullscreenVideo> {
  VideoPlayerController? _controller;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    final controller = VideoPlayerController.file(File(widget.path));
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _chewie = ChewieController(videoPlayerController: controller, autoPlay: true, looping: false));
    });
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(child: _chewie == null ? const CircularProgressIndicator(color: Colors.white) : Chewie(controller: _chewie!)),
    );
  }
}

class _FullscreenVideo extends StatefulWidget {
  final String path;
  const _FullscreenVideo({required this.path});
  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _VoiceBubble extends StatefulWidget {
  final String path;
  final bool isMine;
  const _VoiceBubble({required this.path, required this.isMine});
  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final _player = AudioPlayer();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _loaded = false;
  late final List<double> _bars;

  @override
  void initState() {
    super.initState();
    // A stable pseudo-waveform derived from the file path's hash — purely
    // decorative (this app doesn't analyze real audio amplitude). It just
    // needs to look the same every time this exact message re-renders, not
    // represent the actual recorded waveform.
    final seed = widget.path.hashCode;
    _bars = List.generate(26, (i) {
      final v = ((seed >> (i % 20)) & 0xF) / 15.0;
      return 0.28 + v * 0.72;
    });
    _player.setFilePath(widget.path).then((d) {
      if (!mounted) return;
      setState(() {
        _duration = d ?? Duration.zero;
        _loaded = true;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.isMine ? scheme.onPrimary : scheme.onSurface;
    final dim = fg.withValues(alpha: 0.32);
    final total = _duration.inMilliseconds == 0 ? 1 : _duration.inMilliseconds;
    final progress = (_position.inMilliseconds / total).clamp(0.0, 1.0);
    final playedBars = (progress * _bars.length).round();

    return SizedBox(
      width: 190,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snap) {
              final playing = snap.data?.playing ?? false;
              return InkWell(
                customBorder: const CircleBorder(),
                onTap: !_loaded ? null : () => playing ? _player.pause() : _player.play(),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: fg.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: fg, size: 20),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 22,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List.generate(_bars.length, (i) {
                      final played = i < playedBars;
                      return Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 0.8),
                          height: 22 * _bars[i],
                          decoration: BoxDecoration(color: played ? fg : dim, borderRadius: BorderRadius.circular(2)),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 3),
                Text(_fmt(_position.inMilliseconds > 0 ? _position : _duration), style: TextStyle(fontSize: 10.5, color: fg.withValues(alpha: 0.75))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
