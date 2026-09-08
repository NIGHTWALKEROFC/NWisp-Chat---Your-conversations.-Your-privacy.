import 'package:flutter/material.dart';

/// Shared attachment picker for BOTH 1:1 and group chats — replaces two
/// separately-maintained, byte-for-byte duplicate copies of the same
/// plain ListTile menu (one in chat_detail_screen.dart, one in
/// group_chat_screen.dart) with one shared, nicer-looking grid — the same
/// way voice_recording_bar.dart already unified the voice-message UI
/// between the two screens, instead of two separate implementations.
Future<void> showAttachmentMenu(
  BuildContext context, {
  required VoidCallback onCameraPhoto,
  required VoidCallback onGalleryPhoto,
  required VoidCallback onCameraVideo,
  required VoidCallback onGalleryVideo,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          runSpacing: 20,
          children: [
            _AttachmentOption(
              icon: Icons.photo_camera_outlined,
              label: 'Camera',
              color: scheme.primary,
              onTap: () {
                Navigator.pop(sheetContext);
                onCameraPhoto();
              },
            ),
            _AttachmentOption(
              icon: Icons.photo_outlined,
              label: 'Photo',
              color: const Color(0xFF9C27B0),
              onTap: () {
                Navigator.pop(sheetContext);
                onGalleryPhoto();
              },
            ),
            _AttachmentOption(
              icon: Icons.videocam_outlined,
              label: 'Record video',
              color: const Color(0xFFE53935),
              onTap: () {
                Navigator.pop(sheetContext);
                onCameraVideo();
              },
            ),
            _AttachmentOption(
              icon: Icons.video_library_outlined,
              label: 'Video',
              color: const Color(0xFF00897B),
              onTap: () {
                Navigator.pop(sheetContext);
                onGalleryVideo();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _AttachmentOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AttachmentOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 76,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 8),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
