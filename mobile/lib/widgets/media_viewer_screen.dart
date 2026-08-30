import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

/// One entry in a [MediaViewerScreen] gallery.
class MediaViewerItem {
  final String path;
  final bool isVideo;
  const MediaViewerItem({required this.path, required this.isVideo});
}

/// Feature: in-app media viewer. A full-screen, swipe-between-items
/// gallery for a chat's shared photos/videos, with pinch-to-zoom on
/// photos (via the built-in InteractiveViewer — no extra dependency
/// needed for that part) and a save-to-device action in the app bar
/// (via the `gal` package, added specifically for this).
///
/// This replaces what used to be two separate, single-item-only pages
/// (`_FullscreenImagePage`, `_FullscreenVideoPage` in chat_detail_screen.dart,
/// and their group_chat_screen.dart equivalents) — those already had
/// pinch-zoom and video playback, they just couldn't swipe to the next
/// photo/video or save anything.
class MediaViewerScreen extends StatefulWidget {
  final List<MediaViewerItem> items;
  final int initialIndex;
  const MediaViewerScreen({super.key, required this.items, required this.initialIndex});

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _pageController;
  late int _index;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.isEmpty ? 0 : widget.items.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final item = widget.items[_index];
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Permission needed to save to your device.')),
            );
          }
          return;
        }
      }
      if (item.isVideo) {
        await Gal.putVideo(item.path);
      } else {
        await Gal.putImage(item.path);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(item.isVideo ? 'Video saved to your device.' : 'Photo saved to your device.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save — $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black, body: SizedBox.shrink());
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: widget.items.length > 1
            ? Text('${_index + 1} / ${widget.items.length}', style: const TextStyle(color: Colors.white70, fontSize: 14))
            : null,
        actions: [
          IconButton(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.download_rounded, color: Colors.white),
            tooltip: 'Save to device',
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final item = widget.items[i];
          return item.isVideo ? _VideoPage(path: item.path) : _ZoomableImage(path: item.path);
        },
      ),
    );
  }
}

class _ZoomableImage extends StatelessWidget {
  final String path;
  const _ZoomableImage({required this.path});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InteractiveViewer(
        minScale: 0.8,
        maxScale: 5,
        child: Image.file(File(path)),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  final String path;
  const _VideoPage({required this.path});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    final controller = VideoPlayerController.file(File(widget.path));
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {
        _chewie = ChewieController(videoPlayerController: controller, autoPlay: true, looping: false);
      });
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
    return Center(
      child: _chewie == null
          ? const CircularProgressIndicator(color: Colors.white)
          : Chewie(controller: _chewie!),
    );
  }
}
