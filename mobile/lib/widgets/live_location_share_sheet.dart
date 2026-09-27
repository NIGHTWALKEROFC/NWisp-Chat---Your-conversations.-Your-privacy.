import 'package:flutter/material.dart';
import '../services/live_location_service.dart';

/// Feature: live location sharing — "share for 15 min / 1 hour / 8 hours"
/// duration picker, shown from the attachment menu's "Live location" tile.
/// Handles the permission check/request itself so the caller (chat_detail_
/// screen.dart) doesn't need to know anything about geolocator.
Future<void> showLiveLocationShareSheet(
  BuildContext context, {
  required String conversationId,
  required String recipientUid,
}) async {
  final choice = await showModalBottomSheet<Duration>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Share live location', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(height: 4),
            Text(
              "Your location updates automatically for the time you choose. You can stop early at any time, "
              'and only this chat can see it.',
              style: TextStyle(color: Theme.of(sheetContext).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('15 minutes'),
              onTap: () => Navigator.pop(sheetContext, const Duration(minutes: 15)),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('1 hour'),
              onTap: () => Navigator.pop(sheetContext, const Duration(hours: 1)),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('8 hours'),
              onTap: () => Navigator.pop(sheetContext, const Duration(hours: 8)),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  final hasPermission = await LiveLocationService.hasUsablePermission();
  if (!hasPermission) {
    final granted = await LiveLocationService.requestPermission();
    if (!granted) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission is needed to share your live location.')),
      );
      return;
    }
  }

  try {
    await LiveLocationService.startSharing(conversationId: conversationId, recipientUid: recipientUid, duration: choice);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't start sharing: $e")));
  }
}
