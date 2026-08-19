import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Where decrypted chat media actually lives long-term — inside this app's
/// own sandboxed documents folder, never anywhere shared or public. This is
/// the "store the data on the user's phone itself" half of the media
/// pipeline: Supabase Storage only ever holds the ENCRYPTED bytes, and only
/// until the recipient's device confirms it downloaded, decrypted, and
/// saved a copy here (see MessageRelayService._receiveMediaMessage).
class LocalMediaFiles {
  static const _uuid = Uuid();

  static Future<Directory> _mediaDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'chat_media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> save(Uint8List bytes, String extension) async {
    final dir = await _mediaDir();
    final path = p.join(dir.path, '${_uuid.v4()}.$extension');
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Best-effort delete — used whenever a message (or a whole conversation)
  /// is removed locally, so a disappearing message's media actually
  /// disappears from disk too, not just from the messages list.
  static Future<void> delete(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Not worth surfacing — a leftover file on disk is a minor cleanup
      // miss, not a correctness problem.
    }
  }

  /// Wipes the whole local media folder at once — used when a different
  /// account signs in on this device (see SessionService.resetForNewUser),
  /// where every existing file needs to go regardless of which message it
  /// belonged to.
  static Future<void> deleteAll() async {
    try {
      final dir = await _mediaDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
