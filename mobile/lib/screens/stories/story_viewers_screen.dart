import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/story_service.dart';
import '../../widgets/user_avatar.dart';

/// Feature: Stories — who viewed (and, among those, who liked) one of
/// MY OWN stories. Only ever reached from viewing your own story (see
/// StoryViewerScreen) — firestore.rules also independently enforces this
/// is owner-only at the data level, so this screen isn't the only thing
/// stopping someone else from seeing it.
class StoryViewersScreen extends StatelessWidget {
  final String storyId;
  const StoryViewersScreen({super.key, required this.storyId});

  Future<String> _usernameFor(String uid) async {
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    return (doc.data()?['username'] as String?) ?? 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final storyService = StoryService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Viewers')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: storyService.likesStream(storyId),
        builder: (context, likesSnap) {
          final likedUids = (likesSnap.data?.docs.map((d) => d.id) ?? const <String>[]).toSet();
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: storyService.viewersStream(storyId),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(child: Text('No views yet'));
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final uid = docs[index].id;
                  final viewedAt = (docs[index].data()['viewedAt'] as Timestamp?)?.toDate();
                  return FutureBuilder<String>(
                    future: _usernameFor(uid),
                    builder: (context, userSnap) {
                      final name = userSnap.data ?? '...';
                      return ListTile(
                        leading: UserAvatar(uid: uid, name: name, radius: 18),
                        title: Text(name),
                        subtitle: viewedAt != null ? Text(_relativeTime(viewedAt)) : null,
                        trailing: likedUids.contains(uid)
                            ? const Icon(Icons.favorite, color: Colors.redAccent, size: 20)
                            : null,
                      );
                    },
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
