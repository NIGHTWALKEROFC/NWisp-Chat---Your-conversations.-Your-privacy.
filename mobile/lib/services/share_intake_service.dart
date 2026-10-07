import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SharedFile {
  final String path;
  final String mime;
  const SharedFile(this.path, this.mime);
  bool get isVideo => mime.startsWith('video/');
}

/// What another app shared to NWisp: some text / a link and/or pictures and
/// videos (already copied into NWisp's own cache by the Android side).
class SharedContent {
  final String? text;
  final List<SharedFile> files;
  const SharedContent({this.text, this.files = const []});

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty;

  String get summary {
    final parts = <String>[];
    if (text != null && text!.trim().isNotEmpty) parts.add('text');
    final images = files.where((f) => !f.isVideo).length;
    final videos = files.where((f) => f.isVideo).length;
    if (images > 0) parts.add(images == 1 ? '1 photo' : '$images photos');
    if (videos > 0) parts.add(videos == 1 ? '1 video' : '$videos videos');
    return parts.join(' + ');
  }
}

/// Feature: Share to NWisp from other apps (Gallery, Chrome, Files …).
///
/// The Android side (MainActivity.collectShare) catches the share and copies
/// the files; this class hands the result to the app. HomeShell opens the
/// "Send to…" screen — HomeShell only exists after sign-in and unlock, so a
/// share can never get around the app lock.
class ShareIntakeService {
  ShareIntakeService._();
  static final instance = ShareIntakeService._();

  static const _channel = MethodChannel('com.nightwalker.securechat/share');

  /// Set when something was shared and nobody has handled it yet.
  final ValueNotifier<SharedContent?> pending = ValueNotifier(null);

  bool _started = false;

  Future<void> init() async {
    if (!_started) {
      _started = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'shareReceived') await _take();
      });
    }
    await _take();
  }

  Future<void> _take() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('takePending');
      if (m == null) return;
      final files = <SharedFile>[
        for (final f in (m['files'] as List? ?? const []))
          SharedFile((f as Map)['path'] as String, (f['mime'] as String?) ?? 'image/jpeg'),
      ];
      final content = SharedContent(text: m['text'] as String?, files: files);
      if (!content.isEmpty) pending.value = content;
    } catch (e) {
      debugPrint('ShareIntakeService: $e');
    }
  }

  void clear() => pending.value = null;
}
