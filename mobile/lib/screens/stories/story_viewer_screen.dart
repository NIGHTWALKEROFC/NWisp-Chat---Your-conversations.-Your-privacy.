import 'dart:async';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../services/media_compression_service.dart';
import '../../services/story_service.dart';
import 'story_viewers_screen.dart';

/// Feature: Stories — the full-screen viewer. Shown one user's stories at
/// a time, oldest first, auto-advancing (photos: a fixed 6 seconds;
/// videos: their own real length) with a tap to skip forward/back and a
/// long-press to pause. Downloads and decrypts each story's media only
/// when it's actually about to be shown (see
/// StoryService.downloadAndDecrypt) — nothing is pre-fetched.
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

  bool get _isMine => widget.ownerUid == FirebaseAuth.instance.currentUser?.uid;
  Map<String, dynamic> get _current => widget.stories[_index];

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _goNext();
      });
    _loadCurrent();
  }

  @override
  void dispose() {
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
    _storyService.myLikeStream(_current['id'] as String).first.then((liked) {
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
    _progress.forward();
    _videoController?.play();
  }

  Future<void> _toggleLike() async {
    setState(() => _liked = !_liked);
    await _storyService.setLiked(_current['id'] as String, _liked);
  }

  @override
  Widget build(BuildContext context) {
    final caption = (_current['caption'] as String?) ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
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
                    CircleAvatar(radius: 16, child: Text(widget.ownerName.isNotEmpty ? widget.ownerName[0].toUpperCase() : '?')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.ownerName,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
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
                      )
                    else
                      IconButton(
                        icon: Icon(_liked ? Icons.favorite : Icons.favorite_border, color: _liked ? Colors.redAccent : Colors.white),
                        onPressed: _toggleLike,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
