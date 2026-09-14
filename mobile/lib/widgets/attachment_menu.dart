import 'package:flutter/material.dart';

/// Shared attachment picker for BOTH 1:1 and group chats — replaces two
/// separately-maintained, byte-for-byte duplicate copies of the same
/// plain ListTile menu (one in chat_detail_screen.dart, one in
/// group_chat_screen.dart) with one shared, nicer-looking grid — the same
/// way voice_recording_bar.dart already unified the voice-message UI
/// between the two screens, instead of two separate implementations.
///
/// Feature: view-once media. UPDATED — this used to add one extra,
/// camera-photo-only "View once" tile alongside the normal four. That
/// meant gallery photos and any video (camera OR gallery) couldn't be
/// sent as view-once at all. Replaced with a "Send as view once" toggle
/// at the top of the sheet instead: turn it on, then tap ANY of the four
/// normal options below — camera photo, gallery photo, record video, or
/// gallery video — and that one send goes out as view-once. Off by
/// default, and it resets every time the sheet is reopened rather than
/// staying on — sending one view-once photo shouldn't silently make the
/// next five photos view-once too if someone forgets it's on.
Future<void> showAttachmentMenu(
  BuildContext context, {
  required VoidCallback onCameraPhoto,
  required VoidCallback onGalleryPhoto,
  required VoidCallback onCameraVideo,
  required VoidCallback onGalleryVideo,
  VoidCallback? onCameraPhotoViewOnce,
  VoidCallback? onGalleryPhotoViewOnce,
  VoidCallback? onCameraVideoViewOnce,
  VoidCallback? onGalleryVideoViewOnce,
}) {
  final scheme = Theme.of(context).colorScheme;
  // Any caller that hasn't wired up the view-once callbacks yet (there
  // shouldn't be any left in this app, but this keeps the sheet safe for
  // any future caller that reuses it without them) just never shows the
  // toggle at all, and every tile behaves exactly as it did before this
  // feature existed.
  final viewOnceAvailable = onCameraPhotoViewOnce != null || onGalleryPhotoViewOnce != null || onCameraVideoViewOnce != null || onGalleryVideoViewOnce != null;

  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setState) {
        var viewOnce = false;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (viewOnceAvailable)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FilterChip(
                      avatar: Icon(Icons.remove_red_eye_outlined, size: 18, color: viewOnce ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
                      label: const Text('Send as view once'),
                      selected: viewOnce,
                      onSelected: (v) => setState(() => viewOnce = v),
                    ),
                  ),
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  runSpacing: 20,
                  children: [
                    _AttachmentOption(
                      icon: Icons.photo_camera_outlined,
                      label: 'Camera',
                      color: scheme.primary,
                      onTap: () {
                        Navigator.pop(sheetContext);
                        (viewOnce && onCameraPhotoViewOnce != null) ? onCameraPhotoViewOnce() : onCameraPhoto();
                      },
                    ),
                    _AttachmentOption(
                      icon: Icons.photo_outlined,
                      label: 'Photo',
                      color: const Color(0xFF9C27B0),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        (viewOnce && onGalleryPhotoViewOnce != null) ? onGalleryPhotoViewOnce() : onGalleryPhoto();
                      },
                    ),
                    _AttachmentOption(
                      icon: Icons.videocam_outlined,
                      label: 'Record video',
                      color: const Color(0xFFE53935),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        (viewOnce && onCameraVideoViewOnce != null) ? onCameraVideoViewOnce() : onCameraVideo();
                      },
                    ),
                    _AttachmentOption(
                      icon: Icons.video_library_outlined,
                      label: 'Video',
                      color: const Color(0xFF00897B),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        (viewOnce && onGalleryVideoViewOnce != null) ? onGalleryVideoViewOnce() : onGalleryVideo();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
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
