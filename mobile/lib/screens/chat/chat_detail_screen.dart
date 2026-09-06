import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/local_message.dart';
import '../../services/auth_service.dart';
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
import '../../services/voice_recording_controller.dart';
import '../../widgets/media_viewer_screen.dart';
import '../../widgets/voice_message_bubble.dart';
import '../../widgets/voice_recording_bar.dart';
import 'chat_search_screen.dart';
import 'chat_settings_screen.dart';

// Expanded quick-reaction set (was 6, now 12) — tapping the same emoji you
// already reacted with removes it; tapping a different one switches to it.
const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉', '😍', '👏', '💯', '😡'];

class ChatDetailScreen extends StatefulWidget {
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
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _conversationService = ConversationService();
  final _moderationService = ModerationService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

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

  int? _profileTtlHours;
  int? _chatTtlOverride;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _convoSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _blockSub;

  int get _effectiveTtlHours => _chatTtlOverride ?? _profileTtlHours ?? 0; // 0 = never — opt-in disappearing messages

  @override
  void initState() {
    super.initState();
    // Screenshot / screen-recording prevention (Android FLAG_SECURE) —
    // see ScreenshotGuardService. Released in dispose() below.
    ScreenshotGuardService.acquire();
    _conversationService.ensureConversation(otherUid: widget.peerUid);
    // BUGFIX: messageTtlHours/readReceiptsEnabled moved to the owner-only
    // users/{uid}/private/profile doc (see firestore.rules) — read from
    // there now instead of the public users/{uid} doc.
    AuthService().currentUserPrivateProfile().then((doc) {
      if (!mounted) return;
      setState(() {
        _profileTtlHours = (doc.data()?['messageTtlHours'] as num?)?.toInt();
        _readReceiptsEnabled = (doc.data()?['readReceiptsEnabled'] as bool?) ?? true;
      });
    });
    _convoSub = _conversationService.conversationStream(widget.conversationId).listen((doc) {
      if (!mounted) return;
      setState(() => _chatTtlOverride = (doc.data()?['chatTtlHours'] as num?)?.toInt());
    });
    _blockSub = _moderationService.myProfileStream().listen((doc) {
      if (!mounted) return;
      final blocked = List<String>.from(doc.data()?['blockedUsers'] ?? []);
      setState(() => _peerBlockedByMe = blocked.contains(widget.peerUid));
    });
    PinService.pinnedFor(widget.conversationId).then((ids) {
      if (mounted) setState(() => _pinnedIds = ids);
    });
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    _conversationService.setTyping(widget.conversationId, false);
    _convoSub?.cancel();
    _blockSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _voiceController.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _conversationService.setTyping(widget.conversationId, value.isNotEmpty);
    setState(() {}); // toggles the compose bar between the mic icon and the send icon
  }

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

  Future<void> _send() async {
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
      setState(() => _editingMessage = null);
      try {
        await MessageRelayService.editMessage(
          conversationId: widget.conversationId,
          toUid: widget.peerUid,
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
    setState(() => _replyingTo = null);
    Future<void> attemptSend() => MessageRelayService.sendMessage(
          conversationId: widget.conversationId,
          recipientUid: widget.peerUid,
          text: text,
          replyToId: replyId,
          ttlHours: _effectiveTtlHours,
        );
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
    } on RateLimitedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message not sent — $e'), duration: const Duration(seconds: 6)));
    }
    await _conversationService.setTyping(widget.conversationId, false);
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
      compress: (file) => MediaCompressionService.compressImage(file),
    );
  }

  Future<void> _pickAndSendVideo(ImageSource source) async {
    // Cap recording/selection length at 2 minutes — a longer clip is very
    // unlikely to compress under the 5MB cap at any watchable quality, so
    // it's better to stop the user before they wait through a compression
    // pass that's doomed to fail than after.
    final picked = await ImagePicker().pickVideo(source: source, maxDuration: const Duration(minutes: 2));
    if (picked == null) return;
    await _sendMedia(
      file: File(picked.path),
      messageType: 'video',
      mime: 'video/mp4',
      compress: (file) async => (await MediaCompressionService.compressVideo(file)).readAsBytesSync(),
    );
  }

  Future<void> _sendMedia({
    required File file,
    required String messageType,
    required String mime,
    required Future<List<int>> Function(File) compress,
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

  void _copySelected() {
    final ordered = _messages.where((m) => _selectedIds.contains(m.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final text = ordered.map((m) => m.text).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _selectedIds.clear());
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: _selectedIds.isEmpty ? _buildNormalAppBar(scheme) : _buildSelectionAppBar(scheme),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter(color: scheme.onSurface.withValues(alpha: 0.05))),
          ),
          Column(
            children: [
              if (_pinnedIds.isNotEmpty) _buildPinnedBanner(scheme),
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
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_scrollController.hasClients) {
                        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                      }
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
                        LocalMessage? replySource;
                        if (msg.replyToId != null) {
                          for (final m in messages) {
                            if (m.id == msg.replyToId) {
                              replySource = m;
                              break;
                            }
                          }
                        }
                        final uid = _myUid;
                        return KeyedSubtree(
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
                            mediaGallery: messages
                                .where((m) => m.mediaPath != null && (m.messageType == 'image' || m.messageType == 'video'))
                                .map((m) => MediaViewerItem(path: m.mediaPath!, isVideo: m.messageType == 'video'))
                                .toList(),
                            mediaGalleryIndex: messages
                                .where((m) => m.mediaPath != null && (m.messageType == 'image' || m.messageType == 'video'))
                                .toList()
                                .indexWhere((m) => m.id == msg.id),
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
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      widget.peerUsername.isNotEmpty ? widget.peerUsername[0].toUpperCase() : '?',
                      style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                    ),
                  ),
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
          ),
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
        IconButton(icon: const Icon(Icons.copy_outlined), tooltip: 'Copy', onPressed: _copySelected),
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
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isMine ? 18 : 4),
      bottomRight: Radius.circular(isMine ? 4 : 18),
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
                      gradient: isMine
                          ? LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [scheme.primary, scheme.primary.withValues(alpha: 0.82)],
                            )
                          : null,
                      color: isMine ? null : scheme.surfaceContainerHigh,
                      borderRadius: radius,
                      boxShadow: isMine
                          ? [
                              BoxShadow(
                                color: scheme.primary.withValues(alpha: 0.25),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                        if (messageType == 'image' && mediaPath != null)
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
                          ),
                        if (text.isNotEmpty)
                          RichText(
                            text: TextSpan(
                              style: TextStyle(color: isMine ? scheme.onPrimary : scheme.onSurface),
                              children: [
                                TextSpan(text: text),
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
