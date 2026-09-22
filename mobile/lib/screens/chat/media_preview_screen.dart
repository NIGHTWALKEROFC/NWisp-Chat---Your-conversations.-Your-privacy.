import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../services/screenshot_guard_service.dart';

/// What the person decided in the preview.
class MediaPreviewResult {
  /// The file to send — the original if nothing was edited, otherwise the
  /// edited copy.
  final File file;

  /// "View once" was switched on for this photo/video.
  final bool viewOnce;

  const MediaPreviewResult({required this.file, required this.viewOnce});
}

/// Opens the preview for a photo or video the person just picked/captured.
/// Resolves to null if they backed out (nothing is sent).
///
/// Feature: media preview. Photos/videos used to be sent the instant they
/// were picked. Now there's a WhatsApp/Telegram-style step first: look at it,
/// (photos) crop / rotate / draw / add text, decide "view once", then send.
Future<MediaPreviewResult?> showMediaPreview(
  BuildContext context, {
  required File file,
  required bool isVideo,
  required String recipientLabel,
  bool initialViewOnce = false,
  // Feature: profile photo editing. Same crop / rotate / draw / text tools,
  // but no "view once" button and the confirm button is a tick (OK) instead
  // of a send arrow. Used for profile and community photos.
  bool forProfilePhoto = false,
}) {
  return Navigator.push<MediaPreviewResult>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaPreviewScreen(
        file: file,
        isVideo: isVideo,
        recipientLabel: recipientLabel,
        initialViewOnce: initialViewOnce,
        forProfilePhoto: forProfilePhoto,
      ),
    ),
  );
}

enum _Mode { view, draw, text, crop }

class _Stroke {
  final Color color;
  final double width; // fraction of the image's shorter side
  final List<Offset> points = []; // each 0..1 of the image
  _Stroke(this.color, this.width);
}

class _TextItem {
  String text;
  Offset center; // 0..1 of the image
  Color color;
  final double size; // fraction of the image's shorter side
  _TextItem(this.text, this.center, this.color, this.size);
}

const _palette = <Color>[
  Colors.white,
  Colors.black,
  Color(0xFFE53935),
  Color(0xFFFFB300),
  Color(0xFF43A047),
  Color(0xFF1E88E5),
  Color(0xFF8E24AA),
];

/// Keeps [v] between [lo] and [hi] — explicitly a double (num.clamp can be
/// typed as `num`, which won't go into an Offset).
double _cl(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

TextPainter _layoutText(_TextItem t, Size size) {
  final shortest = math.min(size.width, size.height);
  return TextPainter(
    text: TextSpan(
      text: t.text,
      style: TextStyle(
        color: t.color,
        fontSize: t.size * shortest,
        fontWeight: FontWeight.w700,
        shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    maxLines: 8,
  )..layout(maxWidth: size.width * 0.9);
}

Rect _textRect(_TextItem t, Size size) {
  final tp = _layoutText(t, size);
  final center = Offset(t.center.dx * size.width, t.center.dy * size.height);
  return Rect.fromCenter(center: center, width: tp.width, height: tp.height);
}

/// Draws the pen strokes and text on top of an image of size [size]. Used both
/// for the live preview and for the final export, so what you see is exactly
/// what gets sent (sizes are fractions of the image, so it scales cleanly).
void _paintOverlays(Canvas canvas, Size size, List<_Stroke> strokes, List<_TextItem> texts, {int? activeText}) {
  final shortest = math.min(size.width, size.height);
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    final stroke = s.width * shortest;
    if (s.points.length == 1) {
      final p = s.points.first;
      canvas.drawCircle(Offset(p.dx * size.width, p.dy * size.height), stroke / 2, Paint()..color = s.color);
      continue;
    }
    final path = Path()..moveTo(s.points.first.dx * size.width, s.points.first.dy * size.height);
    for (final p in s.points.skip(1)) {
      path.lineTo(p.dx * size.width, p.dy * size.height);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = s.color
        ..strokeWidth = stroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }
  for (var i = 0; i < texts.length; i++) {
    final t = texts[i];
    final tp = _layoutText(t, size);
    final rect = _textRect(t, size);
    tp.paint(canvas, rect.topLeft);
    if (activeText == i) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(6), const Radius.circular(6)),
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }
}

class _OverlayPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final List<_TextItem> texts;
  final int? activeText;
  final int revision; // bumped on every change so repaint is triggered

  _OverlayPainter(this.strokes, this.texts, this.activeText, this.revision);

  @override
  void paint(Canvas canvas, Size size) => _paintOverlays(canvas, size, strokes, texts, activeText: activeText);

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => old.revision != revision || old.activeText != activeText;
}

class _CropPainter extends CustomPainter {
  final Rect crop; // 0..1
  _CropPainter(this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(crop.left * size.width, crop.top * size.height, crop.width * size.width, crop.height * size.height);
    final dim = Path()
      ..addRect(Offset.zero & size)
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final grid = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(r.left + r.width * i / 3, r.top), Offset(r.left + r.width * i / 3, r.bottom), grid);
      canvas.drawLine(Offset(r.left, r.top + r.height * i / 3), Offset(r.right, r.top + r.height * i / 3), grid);
    }
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 9, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.crop != crop;
}

class MediaPreviewScreen extends StatefulWidget {
  final File file;
  final bool isVideo;
  final String recipientLabel;
  final bool initialViewOnce;
  final bool forProfilePhoto;

  const MediaPreviewScreen({
    super.key,
    required this.file,
    required this.isVideo,
    required this.recipientLabel,
    this.initialViewOnce = false,
    this.forProfilePhoto = false,
  });

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  late bool _viewOnce = widget.initialViewOnce;
  bool _shownViewOnceHint = false;
  bool _working = false;

  // ---- photo editing ----
  ui.Image? _image;
  bool _loadFailed = false;
  bool _edited = false;
  _Mode _mode = _Mode.view;
  final List<_Stroke> _strokes = [];
  final List<_TextItem> _texts = [];
  int? _activeText;
  int _revision = 0;
  Color _penColor = const Color(0xFFE53935);
  Rect _crop = const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
  int? _cropCorner; // 0 tl, 1 tr, 2 bl, 3 br
  bool _cropMoving = false;
  bool _draggingText = false;

  // ---- video ----
  VideoPlayerController? _video;
  bool _videoFailed = false;

  @override
  void initState() {
    super.initState();
    // A private photo/video must never end up in a screenshot or the recents preview.
    ScreenshotGuardService.acquire();
    if (widget.isVideo) {
      _initVideo();
    } else {
      _loadImage();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    ScreenshotGuardService.release();
    // (Decoded ui.Images are intentionally not disposed by hand: one could
    // still be mid-paint, and Flutter frees them on its own.)
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Loading
  // ------------------------------------------------------------------

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final first = frame.image;
    final longest = math.max(first.width, first.height);
    // Huge camera photos are scaled down for editing (they're compressed to
    // under 2000px before sending anyway) so a 50-megapixel shot can't run
    // the phone out of memory.
    if (longest <= 3072) return first;
    final scale = 3072 / longest;
    final targetWidth = (first.width * scale).round();
    final codec2 = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
    return (await codec2.getNextFrame()).image;
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final image = await _decode(bytes);
      if (!mounted) return;
      setState(() => _image = image);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
    }
  }

  Future<void> _initVideo() async {
    try {
      final controller = VideoPlayerController.file(widget.file);
      _video = controller;
      await controller.initialize();
      await controller.setLooping(true);
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      await controller.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _videoFailed = true);
    }
  }

  // ------------------------------------------------------------------
  // Editing operations
  // ------------------------------------------------------------------

  void _touch() {
    _revision++;
    _edited = true;
  }

  Future<ui.Image> _composite() async {
    final img = _image!;
    final w = img.width.toDouble();
    final h = img.height.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    canvas.drawImage(img, Offset.zero, Paint());
    _paintOverlays(canvas, Size(w, h), _strokes, _texts);
    return recorder.endRecording().toImage(img.width, img.height);
  }

  void _setImage(ui.Image image) {
    _image = image;
    _strokes.clear();
    _texts.clear();
    _activeText = null;
    _edited = true;
    _revision++;
  }

  Future<void> _rotate() async {
    if (_image == null || _working) return;
    setState(() => _working = true);
    try {
      final baked = await _composite(); // pen/text turn with the picture
      final w = baked.width;
      final h = baked.height;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, h.toDouble(), w.toDouble()));
      canvas.translate(h.toDouble(), 0);
      canvas.rotate(math.pi / 2);
      canvas.drawImage(baked, Offset.zero, Paint());
      final rotated = await recorder.endRecording().toImage(h, w);
      if (!mounted) return;
      setState(() {
        _setImage(rotated);
        _working = false;
      });
    } catch (_) {
      if (mounted) setState(() => _working = false);
    }
  }

  void _startCrop() {
    setState(() {
      _mode = _Mode.crop;
      _crop = const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
      _activeText = null;
    });
  }

  Future<void> _applyCrop() async {
    if (_image == null || _working) return;
    setState(() => _working = true);
    try {
      final baked = await _composite();
      final bw = baked.width;
      final bh = baked.height;
      final src = Rect.fromLTWH(_crop.left * bw, _crop.top * bh, _crop.width * bw, _crop.height * bh);
      final cw = math.max(1, math.min(bw, src.width.round()));
      final ch = math.max(1, math.min(bh, src.height.round()));
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()));
      canvas.drawImageRect(baked, src, Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()), Paint());
      final cropped = await recorder.endRecording().toImage(cw, ch);
      if (!mounted) return;
      setState(() {
        _setImage(cropped);
        _mode = _Mode.view;
        _working = false;
      });
    } catch (_) {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _resetEdits() async {
    setState(() {
      _working = true;
      _mode = _Mode.view;
    });
    try {
      final image = await _decode(await widget.file.readAsBytes());
      if (!mounted) return;
      setState(() {
        _image = image;
        _strokes.clear();
        _texts.clear();
        _activeText = null;
        _edited = false;
        _revision++;
        _working = false;
      });
    } catch (_) {
      if (mounted) setState(() => _working = false);
    }
  }

  void _undo() {
    setState(() {
      if (_texts.isNotEmpty && _mode == _Mode.text) {
        _texts.removeLast();
        _activeText = null;
      } else if (_strokes.isNotEmpty) {
        _strokes.removeLast();
      } else if (_texts.isNotEmpty) {
        _texts.removeLast();
        _activeText = null;
      }
      _revision++;
      _edited = _strokes.isNotEmpty || _texts.isNotEmpty || _edited;
    });
  }

  Future<void> _addText() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Type something'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _texts.add(_TextItem(text, const Offset(0.5, 0.5), _penColor, 0.07));
      _activeText = _texts.length - 1;
      _touch();
    });
  }

  // ------------------------------------------------------------------
  // Gestures on the photo
  // ------------------------------------------------------------------

  Offset _norm(Offset local, Size size) => Offset(
        _cl(local.dx / size.width, 0, 1),
        _cl(local.dy / size.height, 0, 1),
      );

  void _panStart(DragStartDetails d, Size size) {
    switch (_mode) {
      case _Mode.draw:
        final stroke = _Stroke(_penColor, 0.009)..points.add(_norm(d.localPosition, size));
        setState(() {
          _strokes.add(stroke);
          _touch();
        });
        break;
      case _Mode.text:
        var hit = -1;
        for (var i = _texts.length - 1; i >= 0; i--) {
          if (_textRect(_texts[i], size).inflate(14).contains(d.localPosition)) {
            hit = i;
            break;
          }
        }
        setState(() {
          _activeText = hit >= 0 ? hit : null;
          _draggingText = hit >= 0;
        });
        break;
      case _Mode.crop:
        final p = d.localPosition;
        final r = Rect.fromLTWH(_crop.left * size.width, _crop.top * size.height, _crop.width * size.width, _crop.height * size.height);
        final corners = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
        _cropCorner = null;
        _cropMoving = false;
        for (var i = 0; i < 4; i++) {
          if ((corners[i] - p).distance < 36) {
            _cropCorner = i;
            break;
          }
        }
        if (_cropCorner == null && r.contains(p)) _cropMoving = true;
        break;
      case _Mode.view:
        break;
    }
  }

  void _panUpdate(DragUpdateDetails d, Size size) {
    final dx = d.delta.dx / size.width;
    final dy = d.delta.dy / size.height;
    switch (_mode) {
      case _Mode.draw:
        if (_strokes.isEmpty) return;
        setState(() {
          _strokes.last.points.add(_norm(d.localPosition, size));
          _revision++;
        });
        break;
      case _Mode.text:
        final i = _activeText;
        if (i == null || !_draggingText) return;
        setState(() {
          final c = _texts[i].center;
          _texts[i].center = Offset(_cl(c.dx + dx, 0, 1), _cl(c.dy + dy, 0, 1));
          _revision++;
          _edited = true;
        });
        break;
      case _Mode.crop:
        const minSize = 0.12;
        var l = _crop.left, t = _crop.top, r = _crop.right, b = _crop.bottom;
        if (_cropMoving) {
          final w = r - l, h = b - t;
          l = _cl(l + dx, 0, 1.0 - w);
          t = _cl(t + dy, 0, 1.0 - h);
          r = l + w;
          b = t + h;
        } else if (_cropCorner != null) {
          if (_cropCorner == 0 || _cropCorner == 2) l = _cl(l + dx, 0, r - minSize);
          if (_cropCorner == 1 || _cropCorner == 3) r = _cl(r + dx, l + minSize, 1);
          if (_cropCorner == 0 || _cropCorner == 1) t = _cl(t + dy, 0, b - minSize);
          if (_cropCorner == 2 || _cropCorner == 3) b = _cl(b + dy, t + minSize, 1);
        } else {
          return;
        }
        setState(() => _crop = Rect.fromLTRB(l, t, r, b));
        break;
      case _Mode.view:
        break;
    }
  }

  void _panEnd() {
    _draggingText = false;
    _cropCorner = null;
    _cropMoving = false;
  }

  // ------------------------------------------------------------------
  // Send
  // ------------------------------------------------------------------

  Future<File> _exportEditedImage() async {
    final baked = await _composite();
    final data = await baked.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Could not encode the edited photo');
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/preview_edit_${DateTime.now().microsecondsSinceEpoch}.png');
    await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return out;
  }

  Future<void> _send() async {
    if (_working) return;
    if (widget.isVideo) {
      _video?.pause();
      Navigator.pop(context, MediaPreviewResult(file: widget.file, viewOnce: _viewOnce));
      return;
    }
    if (_image == null) return;
    final hasEdits = _edited || _strokes.isNotEmpty || _texts.isNotEmpty;
    if (!hasEdits) {
      Navigator.pop(context, MediaPreviewResult(file: widget.file, viewOnce: _viewOnce));
      return;
    }
    setState(() => _working = true);
    try {
      final edited = await _exportEditedImage();
      if (!mounted) return;
      Navigator.pop(context, MediaPreviewResult(file: edited, viewOnce: _viewOnce));
    } catch (_) {
      if (!mounted) return;
      setState(() => _working = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't apply your edits. Try again, or reset the photo.")),
      );
    }
  }

  void _toggleViewOnce() {
    setState(() => _viewOnce = !_viewOnce);
    if (_viewOnce && !_shownViewOnceHint) {
      _shownViewOnceHint = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isVideo
                ? 'View once: this video disappears after they watch it.'
                : 'View once: this photo disappears after they open it.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  Widget _toolButton(IconData icon, String tooltip, VoidCallback? onPressed, {bool active = false}) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: onPressed == null ? Colors.white30 : (active ? Theme.of(context).colorScheme.primary : Colors.white)),
    );
  }

  Widget _buildTopBar() {
    final editing = !widget.isVideo && _image != null;
    final canUndo = _strokes.isNotEmpty || _texts.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const Spacer(),
          if (editing && _mode != _Mode.crop) ...[
            if (canUndo) _toolButton(Icons.undo, 'Undo', _undo),
            _toolButton(Icons.crop, 'Crop', _working ? null : _startCrop),
            _toolButton(Icons.rotate_90_degrees_cw, 'Rotate', _working ? null : _rotate),
            _toolButton(Icons.text_fields, 'Text', () {
              setState(() => _mode = _mode == _Mode.text ? _Mode.view : _Mode.text);
              if (_mode == _Mode.text && _texts.isEmpty) _addText();
            }, active: _mode == _Mode.text),
            _toolButton(Icons.edit_outlined, 'Draw', () {
              setState(() {
                _mode = _mode == _Mode.draw ? _Mode.view : _Mode.draw;
                _activeText = null;
              });
            }, active: _mode == _Mode.draw),
            if (_edited || canUndo) _toolButton(Icons.restart_alt, 'Reset edits', _working ? null : _resetEdits),
          ],
        ],
      ),
    );
  }

  Widget _buildPhoto() {
    if (_loadFailed) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text("Couldn't open this photo.", style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    final image = _image;
    if (image == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: AspectRatio(
        aspectRatio: image.width / image.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => _panStart(d, size),
              onPanUpdate: (d) => _panUpdate(d, size),
              onPanEnd: (_) => _panEnd(),
              onTapUp: (d) {
                if (_mode == _Mode.text) {
                  var hit = -1;
                  for (var i = _texts.length - 1; i >= 0; i--) {
                    if (_textRect(_texts[i], size).inflate(14).contains(d.localPosition)) {
                      hit = i;
                      break;
                    }
                  }
                  setState(() => _activeText = hit >= 0 ? hit : null);
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: image, fit: BoxFit.fill),
                  CustomPaint(painter: _OverlayPainter(_strokes, _texts, _mode == _Mode.text ? _activeText : null, _revision)),
                  if (_mode == _Mode.crop) CustomPaint(painter: _CropPainter(_crop)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final c = _video;
    if (_videoFailed) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text("Can't preview this video, but you can still send it.", style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
        ),
      );
    }
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
    return GestureDetector(
      onTap: () => c.value.isPlaying ? c.pause() : c.play(),
      child: Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(c),
              if (!c.value.isPlaying) const Icon(Icons.play_circle_fill, size: 72, color: Colors.white70),
              Positioned(left: 0, right: 0, bottom: 0, child: VideoProgressIndicator(c, allowScrubbing: true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaletteRow() {
    final showPalette = !widget.isVideo && (_mode == _Mode.draw || _mode == _Mode.text);
    if (!showPalette) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final color in _palette)
            GestureDetector(
              onTap: () => setState(() {
                _penColor = color;
                final i = _activeText;
                if (_mode == _Mode.text && i != null) {
                  _texts[i].color = color;
                  _touch();
                }
              }),
              child: Container(
                width: 30,
                height: 30,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: _penColor == color ? Colors.white : Colors.white38, width: _penColor == color ? 3 : 1.5),
                ),
              ),
            ),
          if (_mode == _Mode.text) ...[
            IconButton(tooltip: 'Add text', icon: const Icon(Icons.add_circle_outline, color: Colors.white), onPressed: _addText),
            if (_activeText != null)
              IconButton(
                tooltip: 'Delete text',
                icon: const Icon(Icons.delete_outline, color: Colors.white),
                onPressed: () => setState(() {
                  _texts.removeAt(_activeText!);
                  _activeText = null;
                  _touch();
                }),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme scheme) {
    if (_mode == _Mode.crop) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: () => setState(() => _mode = _Mode.view), child: const Text('Cancel', style: TextStyle(color: Colors.white))),
            FilledButton(onPressed: _working ? null : _applyCrop, child: const Text('Apply crop')),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(24)),
              child: Text(
                widget.recipientLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // "View once" — the circled 1, like WhatsApp/Telegram. Not
          // offered when this screen is editing a profile photo.
          if (!widget.forProfilePhoto) Tooltip(
            message: _viewOnce ? 'View once: on' : 'View once: off',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _toggleViewOnce,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _viewOnce ? scheme.primary : Colors.transparent,
                  border: Border.all(color: _viewOnce ? scheme.primary : Colors.white70, width: 2),
                ),
                child: Text(
                  '1',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: _viewOnce ? scheme.onPrimary : Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FloatingActionButton(
            heroTag: null,
            onPressed: _working ? null : _send,
            child: _working
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Icon(widget.forProfilePhoto ? Icons.check : Icons.send),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: widget.isVideo ? _buildVideo() : _buildPhoto()),
            _buildPaletteRow(),
            _buildBottomBar(scheme),
          ],
        ),
      ),
    );
  }
}
