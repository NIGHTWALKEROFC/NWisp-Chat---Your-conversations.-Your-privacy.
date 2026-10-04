import 'dart:async';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../services/media_compression_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../services/story_reply_service.dart';
import '../../services/story_service.dart';
import '../../widgets/emoji_burst.dart';
import '../../widgets/user_avatar.dart';
import '../chat/chat_detail_screen.dart';
import '../security/chat_pin_guard.dart';
import 'story_viewers_screen.dart';

/// Feature: Stories — the full-screen viewer. Shown one user's stories at
/// a time, oldest first, auto-advancing (photos: a fixed 6 seconds;
/// videos: their own real length) with a tap to skip forward/back and a
/// long-press to pause. Downloads and decrypts each story's media only
/// when it's actually about to be shown (see
/// StoryService.downloadAndDecrypt) — nothing is pre-fetched.
///
/// Screenshots and screen recording are blocked while this screen is open
/// (same always-on FLAG_SECURE protection chats use — see
/// ScreenshotGuardService), and someone else's story has a "Reply..." bar
/// that sends a private, end-to-end-encrypted message to its owner (see
/// StoryReplyService).
class StoryViewerScreen extends StatefulWidget {
  /// This one user's stories, oldest first, each a Firestore doc snapshot
  /// turned into a plain map with its id included as 'id'.
  final List<Map<String, dynamic>> stories;
  final int initialIndex;
  final String ownerUid;
  final String ownerName;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    this.initialIndex = 0,
    required this.ownerUid,
    required this.ownerName,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> with SingleTickerProviderStateMixin {
  final _storyService = StoryService.instance;
  late int _index = widget.initialIndex;
  late AnimationController _progress;

  Uint8List? _mediaBytes;
  VideoPlayerController? _videoController;
  bool _loading = true;
  String? _error;
  bool _liked = false;

  final _replyController = TextEditingController();
  final _replyFocus = FocusNode();
  bool _sendingReply = false;

  // Emoji reactions: the quick row above the reply bar. The burst is the
  // floating-emoji animation; the message is only sent the first time a given
  // emoji is used on a given story, so tapping it over and over is just fun,
  // not spam.
  static const _reactionEmojis = ['😂', '😮', '😢', '👏', '🔥', '🎉'];
  final _burstKey = GlobalKey<EmojiBurstState>();
  final Set<String> _sentReactions = {};

  bool get _isMine => widget.ownerUid == FirebaseAuth.instance.currentUser?.uid;
  Map<String, dynamic> get _current => widget.stories[_index];

  @override
  void initState() {
    super.initState();
    // Blocks screenshots / screen recording for as long as this screen is
    // open. Released in dispose() below.
    ScreenshotGuardService.acquire();
    // Typing a reply pauses the story so it doesn't move on under you.
    _replyFocus.addListener(() {
      // Redraw too: the emoji row hides while the reply box is being typed in.
      if (mounted) setState(() {});
      if (_replyFocus.hasFocus) {
        _pause();
      } else if (!_sendingReply) {
        _resume();
      }
    });
    _progress = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _goNext();
      });
    _loadCurrent();
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    _replyController.dispose();
    _replyFocus.dispose();
    _progress.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    _progress.stop();
    _progress.reset();
    await _videoController?.dispose();
    _videoController = null;
    setState(() {
      _loading = true;
      _error = null;
      _mediaBytes = null;
    });

    // Feature: Stories — a view only counts once you're actually looking
    // at it, not just once it's queued up to load.
    unawaited(_storyService.recordView(_current['id'] as String, widget.ownerUid));
    _storyService.isLiked(_current['id'] as String).then((liked) {
      if (mounted) setState(() => _liked = liked);
    });

    try {
      final bytes = await _storyService.downloadAndDecrypt(_current);
      if (!mounted) return;
      if (_current['mediaType'] == 'video') {
        final file = await MediaCompressionService.writeTemp(bytes, 'mp4');
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        if (!mounted) return;
        _videoController = controller;
        controller.play();
        _progress.duration = controller.value.duration;
      } else {
        _progress.duration = const Duration(seconds: 6);
      }
      setState(() {
        _mediaBytes = bytes;
        _loading = false;
      });
      _progress.forward();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't load this story.";
        });
      }
    }
  }

  Future<void> _confirmDelete() async {
    _pause();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this story?'),
        content: const Text('It is removed from your phone and from your contacts\' phones.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) {
      _resume();
      return;
    }
    await _storyService.deleteStory(_current['id'] as String);
    if (mounted) Navigator.of(context).pop();
  }

  void _goNext() {
    if (_index < widget.stories.length - 1) {
      setState(() => _index++);
      _loadCurrent();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _goPrevious() {
    if (_index > 0) {
      setState(() => _index--);
      _loadCurrent();
    }
  }

  void _pause() {
    _progress.stop();
    _videoController?.pause();
  }

  void _resume() {
    // Nothing to resume while a story is still loading or failed to load
    // (its timer has no duration yet).
    if (_loading || _error != null) return;
    _progress.forward();
    _videoController?.play();
  }

  Future<void> _toggleLike() async {
    setState(() => _liked = !_liked);
    if (_liked) _burstKey.currentState?.burst('❤️', count: 10);
    await _storyService.setLiked(_current['id'] as String, widget.ownerUid, _liked);
  }

  Future<void> _react(String emoji) async {
    _burstKey.currentState?.burst(emoji);
    HapticFeedback.lightImpact();
    if (_isMine) return;
    final key = '${_current['id']}:$emoji';
    if (!_sentReactions.add(key)) return; // already sent this one
    final messenger = ScaffoldMessenger.of(context);
    try {
      await StoryReplyService.sendReaction(ownerUid: widget.ownerUid, story: _current, emoji: emoji);
    } catch (e) {
      _sentReactions.remove(key);
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't send your reaction. Try again.")));
    }
  }

  Widget _buildReactionRow() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final emoji in _reactionEmojis)
            InkResponse(
              radius: 26,
              onTap: () => _react(emoji),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sendingReply || _isMine) return;
    setState(() => _sendingReply = true);
    _pause();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final conversationId = await StoryReplyService.send(
        ownerUid: widget.ownerUid,
        story: _current,
        imageBytes: _current['mediaType'] == 'video' ? null : _mediaBytes,
        text: text,
      );
      if (!mounted) return;
      _replyController.clear();
      _replyFocus.unfocus();
      // Open the chat with the reply in it. If that chat is hidden, locked
      // behind its PIN, or paused, canOpenChat handles it (a hidden chat just
      // stays closed) — the reply itself has already been sent either way.
      final canOpen = await canOpenChat(context, conversationId: conversationId, otherUid: widget.ownerUid);
      if (!mounted) return;
      if (canOpen) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ChatDetailScreen(
              conversationId: conversationId,
              peerUid: widget.ownerUid,
              peerUsername: widget.ownerName,
            ),
          ),
        );
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('Reply sent.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't send your reply: $e")));
    } finally {
      if (mounted) {
        setState(() => _sendingReply = false);
        if (!_replyFocus.hasFocus) _resume();
      }
    }
  }

  Widget _buildReplyBar() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _replyController,
              focusNode: _replyFocus,
              enabled: !_sendingReply,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendReply(),
              decoration: InputDecoration(
                hintText: 'Reply...',
                hintStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Colors.white12,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: const BorderSide(color: Colors.white38),
                ),
              ),
            ),
          ),
          IconButton(
            icon: Icon(_liked ? Icons.favorite : Icons.favorite_border, color: _liked ? Colors.redAccent : Colors.white),
            onPressed: _toggleLike,
          ),
          _sendingReply
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)),
                )
              : IconButton(
                  icon: const Icon(Icons.send_rounded, color: Colors.white),
                  onPressed: _sendReply,
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = (_current['caption'] as String?) ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
        child: GestureDetector(
          onTapUp: (details) {
            final width = MediaQuery.of(context).size.width;
            if (details.globalPosition.dx < width * 0.35) {
              _goPrevious();
            } else {
              _goNext();
            }
          },
          onLongPressStart: (_) => _pause(),
          onLongPressEnd: (_) => _resume(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : _error != null
                        ? Text(_error!, style: const TextStyle(color: Colors.white))
                        : _current['mediaType'] == 'video' && _videoController != null
                            ? AspectRatio(
                                aspectRatio: _videoController!.value.aspectRatio,
                                child: VideoPlayer(_videoController!),
                              )
                            : _mediaBytes != null
                                ? Image.memory(_mediaBytes!, fit: BoxFit.contain)
                                : const SizedBox(),
              ),
              // Progress bars, one per story in this sequence.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(
                  children: [
                    for (var i = 0; i < widget.stories.length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: AnimatedBuilder(
                            animation: _progress,
                            builder: (context, _) {
                              final value = i < _index ? 1.0 : (i == _index ? _progress.value : 0.0);
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: value,
                                  minHeight: 3,
                                  backgroundColor: Colors.white24,
                                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                top: 20,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    UserAvatar(uid: widget.ownerUid, name: widget.ownerName, radius: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.ownerName,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_isMine)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.white),
                        tooltip: 'Delete story',
                        onPressed: _confirmDelete,
                      ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 20,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    if (caption.isNotEmpty)
                      Expanded(
                        child: Text(caption, style: const TextStyle(color: Colors.white)),
                      )
                    else
                      const Spacer(),
                    if (_isMine)
                      TextButton.icon(
                        onPressed: () {
                          _pause();
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => StoryViewersScreen(storyId: _current['id'] as String)),
                          ).then((_) => _resume());
                        },
                        icon: const Icon(Icons.visibility_outlined, color: Colors.white),
                        label: const Text('Viewers', style: TextStyle(color: Colors.white)),
                      ),
                  ],
                ),
              ),
              // Floating emojis from reactions and likes. Never takes a tap.
              Positioned.fill(child: IgnorePointer(child: EmojiBurst(key: _burstKey))),
            ],
          ),
        ),
            ),
            // Someone else's story: the quick emoji row (hidden while typing a
            // reply) and the "Reply..." bar (which also holds the heart).
            if (!_isMine && !_replyFocus.hasFocus) _buildReactionRow(),
            if (!_isMine) _buildReplyBar(),
          ],
        ),
      ),
    );
  }
}
