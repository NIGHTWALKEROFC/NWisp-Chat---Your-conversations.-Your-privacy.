import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/local_message_store.dart';

/// Feature: view-once media. A dedicated, single-item, non-swipeable
/// full-screen viewer for a photo/video the recipient can only open once —
/// deliberately separate from [MediaViewerScreen] (the normal shared
/// swipeable gallery), for a few reasons:
///   - It must show exactly ONE item, never a gallery someone could swipe
///     through past what they were shown.
///   - There's no "save to device" action here on purpose — saving would
///     defeat the entire point of "view once", the same reason WhatsApp/
///     Signal both disable it for their own view-once media.
///   - Closing this screen is the trigger that actually deletes the file
///     (see [LocalMessageStore.consumeViewOnce], called from [dispose]) —
///     MediaViewerScreen has no equivalent lifecycle hook and shouldn't
///     grow one just for this one caller.
///
/// Screenshot/screen-recording blocking is already active the whole time
/// this is open — it's pushed from inside a chat/group screen that has
/// already called ScreenshotGuardService.acquire() in its own initState,
/// and that guard is reference-counted, so this screen doesn't need (and
/// deliberately doesn't add) its own acquire/release pair.
class ViewOnceMediaScreen extends StatefulWidget {
  final String messageId;
  final String path;
  final bool isVideo;
  const ViewOnceMediaScreen({
    super.key,
    required this.messageId,
    required this.path,
    required this.isVideo,
  });

  @override
  State<ViewOnceMediaScreen> createState() => _ViewOnceMediaScreenState();
}

class _ViewOnceMediaScreenState extends State<ViewOnceMediaScreen> {
  VideoPlayerController? _controller;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      final controller = VideoPlayerController.file(File(widget.path));
      _controller = controller;
      controller.initialize().then((_) {
        if (!mounted) return;
        setState(() {
          _chewie = ChewieController(videoPlayerController: controller, autoPlay: true, looping: false);
        });
      });
    }
  }

  @override
  void dispose() {
    // The actual "view once" enforcement: as soon as this screen is
    // closed — back gesture, back button, or the explicit Close button,
    // all of which end up here — the file is gone for good and the
    // message flips to its permanent "Opened" state. This fires exactly
    // once no matter how the screen is closed, since dispose() is a
    // single Flutter lifecycle call, not something each closing path has
    // to remember to call itself.
    LocalMessageStore.consumeViewOnce(widget.messageId);
    _chewie?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('View once', style: TextStyle(color: Colors.white70, fontSize: 14)),
          actions: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Close — this will disappear',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Center(
                child: widget.isVideo
                    ? (_chewie == null
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Chewie(controller: _chewie!))
                    : InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 5,
                        child: Image.file(File(widget.path)),
                      ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Text(
                "This will disappear once you close it — it can't be saved or viewed again.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
