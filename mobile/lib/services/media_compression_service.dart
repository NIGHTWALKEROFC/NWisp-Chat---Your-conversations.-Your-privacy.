import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';

class MediaTooLargeException implements Exception {
  final String message;
  MediaTooLargeException(this.message);
  @override
  String toString() => message;
}

/// Compresses images/video BEFORE anything gets encrypted or uploaded, so
/// the 5MB cap applies to what actually leaves the device.
class MediaCompressionService {
  static const maxBytes = 5 * 1024 * 1024; // 5MB
  static const _uuid = Uuid();

  /// Tries progressively lower quality/dimensions until the result is under
  /// 5MB. Most real photos comfortably compress well below that on the
  /// first or second pass — this only has to work hard on unusually large
  /// source images.
  static Future<Uint8List> compressImage(File file) async {
    final original = await file.length();
    if (original <= maxBytes) {
      final bytes = await file.readAsBytes();
      // Still worth a light pass even under the cap - a raw camera photo
      // can be 8000x6000 and 4.9MB, which is still wasteful to send as-is.
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        quality: 85,
        minWidth: 1920,
        minHeight: 1920,
      );
      return compressed.length <= maxBytes ? compressed : Uint8List.fromList(compressed);
    }

    for (final attempt in [
      (quality: 80, dim: 1920),
      (quality: 65, dim: 1600),
      (quality: 50, dim: 1280),
      (quality: 35, dim: 1024),
    ]) {
      final result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        quality: attempt.quality,
        minWidth: attempt.dim,
        minHeight: attempt.dim,
      );
      if (result != null && result.length <= maxBytes) {
        return Uint8List.fromList(result);
      }
    }

    throw MediaTooLargeException(
      "That image is too large to send even after compression. Try a smaller photo.",
    );
  }

  /// Best-effort video compression via native encoders (H.264, no server
  /// round-trip). Longer/higher-resolution source clips may not fit under
  /// 5MB at a watchable quality — rather than silently degrade to
  /// something illegible, this throws a clear error so the UI can ask for
  /// a shorter clip instead.
  static Future<File> compressVideo(File file) async {
    final original = await file.length();
    if (original <= maxBytes) return file;

    for (final quality in [VideoQuality.MediumQuality, VideoQuality.LowQuality]) {
      final info = await VideoCompress.compressVideo(
        file.path,
        quality: quality,
        deleteOrigin: false,
        includeAudio: true,
      );
      final resultFile = info?.file;
      if (resultFile != null) {
        final size = await resultFile.length();
        if (size <= maxBytes) return resultFile;
        await resultFile.delete().catchError((_) => resultFile);
      }
    }

    throw MediaTooLargeException(
      "That video is too large to fit under 5MB even after compression. Try a shorter clip.",
    );
  }

  /// A small JPEG thumbnail frame, used for the chat bubble preview before
  /// the user taps to actually play the full video.
  static Future<File?> videoThumbnail(File file) async {
    try {
      return await VideoCompress.getFileThumbnail(file.path, quality: 50);
    } catch (_) {
      return null;
    }
  }

  static Future<File> writeTemp(Uint8List bytes, String extension) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_uuid.v4()}.$extension');
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }
}
