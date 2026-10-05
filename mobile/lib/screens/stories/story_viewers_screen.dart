import 'package:flutter/material.dart';
import '../../services/contact_service.dart';
import '../../services/story_service.dart';
import '../../widgets/user_avatar.dart';

/// Feature: Stories — who viewed (and, among those, who liked) one of MY OWN
/// stories. The list lives on this phone: every viewer's phone sent a tiny
/// encrypted "seen" note back (see StoryService.receiveView).
class StoryViewersScreen extends StatelessWidget {
  final String storyId;
  const StoryViewersScreen({super.key, required this.storyId});

  @override
  Widget build(BuildContext context) {
    final contacts = ContactService();
    return Scaffold(
      appBar: AppBar(title: const Text('Viewers')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: StoryService.instance.feed(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          Map<String, dynamic>? story;
          for (final s in snap.data!) {
            if (s['id'] == storyId) story = s;
          }
          final viewers = Map<String, dynamic>.from((story?['viewers'] as Map?) ?? const {});
          final likes = Set<String>.from((story?['likes'] as List?) ?? const <String>[]);
          if (viewers.isEmpty) return const Center(child: Text('No views yet'));
          final uids = viewers.keys.toList()
            ..sort((a, b) => (viewers[b] as int).compareTo(viewers[a] as int));
          return ListView.builder(
            itemCount: uids.length,
            itemBuilder: (context, i) {
              final uid = uids[i];
              final at = DateTime.fromMillisecondsSinceEpoch(viewers[uid] as int);
              return FutureBuilder<String>(
                future: contacts.usernameFor(uid),
                builder: (context, userSnap) {
                  final name = userSnap.data ?? '...';
                  return ListTile(
                    leading: UserAvatar(uid: uid, name: name, radius: 18),
                    title: Text(name),
                    subtitle: Text(_relativeTime(at)),
                    trailing: likes.contains(uid) ? const Icon(Icons.favorite, color: Colors.redAccent, size: 20) : null,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}


/// WhatsApp / Instagram style: the viewers list opens as a panel INSIDE the
/// story (swipe up, or tap the eye / heart counts at the bottom) instead of
/// a separate page. Shows who viewed, with a heart next to who liked.
Future<void> showStoryViewersSheet(BuildContext context, String storyId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (ctx, controller) => _ViewersSheetBody(storyId: storyId, controller: controller),
    ),
  );
}

class _ViewersSheetBody extends StatelessWidget {
  final String storyId;
  final ScrollController controller;
  const _ViewersSheetBody({required this.storyId, required this.controller});

  @override
  Widget build(BuildContext context) {
    final contacts = ContactService();
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: StoryService.instance.feed(),
      builder: (context, snap) {
        Map<String, dynamic>? story;
        for (final s in snap.data ?? const <Map<String, dynamic>>[]) {
          if (s['id'] == storyId) story = s;
        }
        final viewers = Map<String, dynamic>.from((story?['viewers'] as Map?) ?? const {});
        final likes = Set<String>.from((story?['likes'] as List?) ?? const <String>[]);
        final uids = viewers.keys.toList()..sort((a, b) => (viewers[b] as int).compareTo(viewers[a] as int));
        return ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.visibility_outlined, size: 20),
                  const SizedBox(width: 6),
                  Text('${uids.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(width: 18),
                  const Icon(Icons.favorite, size: 20, color: Colors.redAccent),
                  const SizedBox(width: 6),
                  Text('${likes.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ],
              ),
            ),
            const Divider(height: 1),
            if (uids.isEmpty)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(child: Text('No views yet', style: TextStyle(color: scheme.onSurfaceVariant))),
              ),
            for (final uid in uids)
              FutureBuilder<String>(
                future: contacts.usernameFor(uid),
                builder: (context, userSnap) {
                  final name = userSnap.data ?? '...';
                  final at = DateTime.fromMillisecondsSinceEpoch(viewers[uid] as int);
                  return ListTile(
                    leading: UserAvatar(uid: uid, name: name, radius: 18),
                    title: Text(name),
                    subtitle: Text(_ago(at)),
                    trailing: likes.contains(uid) ? const Icon(Icons.favorite, color: Colors.redAccent, size: 20) : null,
                  );
                },
              ),
          ],
        );
      },
    );
  }

  static String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
