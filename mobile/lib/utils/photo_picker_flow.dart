import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../screens/chat/media_preview_screen.dart';

/// The shared "choose a picture, then crop / edit it, then press OK" flow
/// used for profile photos and community photos.
///
/// 1. Ask: camera or gallery.
/// 2. Open the SAME preview/editor the chat uses for photos (crop, rotate,
///    draw, add text) — in profile mode, so there is no "view once" and the
///    confirm button is a tick.
/// 3. Return the finished picture, or null if the person backed out.
///
/// Returns null (never throws) on cancel or any picker problem.
Future<File?> pickAndEditPhoto(BuildContext context, {required String label}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;

  XFile? picked;
  try {
    picked = await ImagePicker().pickImage(source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 92);
  } catch (_) {
    return null;
  }
  if (picked == null || !context.mounted) return null;

  final result = await showMediaPreview(
    context,
    file: File(picked.path),
    isVideo: false,
    recipientLabel: label,
    forProfilePhoto: true,
  );
  return result?.file;
}

/// Shrinks a finished picture to a small square-ish JPEG (max ~512px) so an
/// avatar is a quick download for everyone who sees it.
Future<File> prepareAvatarFile(File source) async {
  try {
    final Uint8List? bytes = await FlutterImageCompress.compressWithFile(
      source.absolute.path,
      quality: 85,
      minWidth: 512,
      minHeight: 512,
    );
    if (bytes == null) return source;
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/avatar_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await out.writeAsBytes(bytes, flush: true);
    return out;
  } catch (_) {
    return source;
  }
}
