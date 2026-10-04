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
