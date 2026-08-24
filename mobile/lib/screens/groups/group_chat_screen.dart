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
import 'group_info_screen.dart';

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉', '😍', '👏', '💯', '😡'];

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

  @override
  void initState() {
    super.initState();
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
    GroupService.instance.setTyping(widget.groupId, value.isNotEmpty);
    setState(() {});
  }

  List<String> get _otherMembers => _memberUids.where((u) => u != _myUid).toList();

  Future<void> _warnAboutPartialFailure(GroupSendPartialFailure e) async {
    await _resolveUsernames(e.failures.map((f) => f.uid));
    if (!mounted) return;
    final names = e.failures.map((f) => _nameFor(f.uid)).join(', ');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Didn't reach: $names — they may need to reopen the app once."), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("You're not signed in. Please sign in again.")));
      return;
    }
    _textController.clear();
    final replyId = _replyingTo?.id;
    setState(() => _replyingTo = null);
    try {
      await GroupMessageRelayService.sendGroupMessage(
        groupId: widget.groupId,
        memberUids: _otherMembers,
        text: text,
        replyToId: replyId,
        ttlHours: _ttlHours,
      );
    } on GroupSendPartialFailure catch (e) {
      await _warnAboutPartialFailure(e);
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $e')));
    }
    await GroupService.instance.setTyping(widget.groupId, false);
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
    final mine = message.reactions[_myUid];
    final next = mine == emoji ? null : emoji;
    await LocalMessageStore.setReaction(message.id, _myUid!, next);
    await GroupMessageRelayService.sendReaction(
      groupId: widget.groupId,
      memberUids: _memberUids,
      messageId: message.id,
      emoji: next,
    );
  }

  void _showMessageActions(LocalMessage message) {
    final mine = message.isMine;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: _quickReactions.map((e) {
                  return IconButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _react(message, e);
                    },
                    icon: Text(e, style: const TextStyle(fontSize: 22)),
                  );
                }).toList(),
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
                leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                title: Text('Delete for everyone', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  GroupMessageRelayService.deleteForEveryone(
                    groupId: widget.groupId,
                    memberUids: _memberUids,
                    messageId: message.id,
                  );
                },
              ),
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

  Widget _bubbleFor(LocalMessage message) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isMine;
    final replyTarget = _findMessage(message.replyToId);

    Widget content;
    switch (message.messageType) {
      case 'image':
        content = message.mediaPath == null ? const Text('Photo unavailable') : _ImageBubble(path: message.mediaPath!);
        break;
      case 'video':
        content = message.mediaPath == null ? const Text('Video unavailable') : _VideoBubble(path: message.mediaPath!);
        break;
      case 'voice':
        content = message.mediaPath == null ? const Text('Voice message unavailable') : _VoiceBubble(path: message.mediaPath!, isMine: mine);
        break;
      default:
        content = Text(message.text, style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface));
    }

    return GestureDetector(
      onLongPress: () => _showMessageActions(message),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: mine ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(_nameFor(message.senderUid), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
                ),
              if (replyTarget != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: (mine ? scheme.onPrimary : scheme.primary).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_nameFor(replyTarget.senderUid)}: ${replyTarget.messageType == 'text' ? replyTarget.text : replyTarget.messageType}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: mine ? scheme.onPrimary : scheme.onSurfaceVariant),
                  ),
                ),
              content,
              if (message.reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 2,
                    children: message.reactions.values.toSet().map((e) => Text(e, style: const TextStyle(fontSize: 13))).toList(),
                  ),
                ),
            ],
          ),
        ),
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
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(child: Text('No messages yet — say hi 👋', style: TextStyle(color: scheme.onSurfaceVariant)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) => _bubbleFor(_messages[i]),
                  ),
          ),
          if (_replyingTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: scheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to ${_nameFor(_replyingTo!.senderUid)}: ${_replyingTo!.messageType == 'text' ? _replyingTo!.text : _replyingTo!.messageType}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyingTo = null)),
                ],
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _cancelVoiceRecording),
          Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
          const SizedBox(width: 6),
          Text('Recording voice message… ${_recordSeconds}s', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const Spacer(),
          IconButton(icon: Icon(Icons.send, color: scheme.primary), onPressed: _stopAndSendVoiceRecording, tooltip: 'Send voice message'),
        ],
      ),
    );
  }

  Widget _buildComposeBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.attach_file_outlined), onPressed: _sendingMedia ? null : _showAttachSheet),
          Expanded(
            child: TextField(
              controller: _textController,
              onChanged: _onTextChanged,
              minLines: 1,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Message',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _sendingMedia
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: Icon(_textController.text.trim().isEmpty ? Icons.mic : Icons.send, color: scheme.primary),
                  onPressed: _textController.text.trim().isEmpty ? _startVoiceRecording : _send,
                ),
        ],
      ),
    );
  }
}

// ---- inline media bubble widgets — kept local to this screen since the
// equivalents in chat_detail_screen.dart are library-private to that file --

class _ImageBubble extends StatelessWidget {
  final String path;
  const _ImageBubble({required this.path});
  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _FullscreenImage(path: path))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, minWidth: 160),
          child: file.existsSync()
              ? Image.file(file, fit: BoxFit.cover)
              : Container(color: Colors.black12, height: 160, alignment: Alignment.center, child: const Icon(Icons.broken_image_outlined)),
        ),
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

class _FullscreenVideo extends StatefulWidget {
  final String path;
  const _FullscreenVideo({required this.path});
  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
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

  @override
  void initState() {
    super.initState();
    _player.setFilePath(widget.path).then((d) {
      if (!mounted) return;
      setState(() {
        _duration = d ?? Duration.zero;
        _loaded = true;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
    _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
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
    final total = _duration.inMilliseconds == 0 ? 1 : _duration.inMilliseconds;
    final progress = (_position.inMilliseconds / total).clamp(0.0, 1.0);
    return SizedBox(
      width: 200,
      child: Row(
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: !_loaded ? null : () => _player.playing ? _player.pause() : _player.play(),
            icon: StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (context, snap) =>
                  Icon(snap.data?.playing ?? false ? Icons.pause_circle_filled : Icons.play_circle_fill, color: fg, size: 30),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: progress, minHeight: 4, backgroundColor: fg.withValues(alpha: 0.25), valueColor: AlwaysStoppedAnimation(fg)),
                ),
                const SizedBox(height: 4),
                Text(_fmt(_position.inMilliseconds > 0 ? _position : _duration), style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.8))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
