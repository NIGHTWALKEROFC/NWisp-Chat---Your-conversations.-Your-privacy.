import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/contact_service.dart';
import '../../services/story_service.dart';
import '../../widgets/nwisp_ui.dart';
import '../../widgets/user_avatar.dart';
import 'story_composer_screen.dart';
import 'story_viewer_screen.dart';

/// Feature: Stories — the bottom-nav tab (see HomeShell). Shows "Your
/// story" first (post one if you don't have one, otherwise view your own
/// with a tap), then everyone else with an active, not-yet-expired story
/// you're allowed to see, most recently posted first. A colored ring
/// means at least one of their stories is new to you; a grey ring means
/// you've already seen all of them.
class StoriesTabScreen extends StatefulWidget {
  const StoriesTabScreen({super.key});

  @override
  State<StoriesTabScreen> createState() => _StoriesTabScreenState();
}

class _StoriesTabScreenState extends State<StoriesTabScreen> {
  final _storyService = StoryService.instance;
  final Map<String, String> _usernameCache = {};

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final name = await ContactService().usernameFor(uid);
    _usernameCache[uid] = name;
    return name;
  }

  Future<void> _openComposer() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const StoryComposerScreen()));
  }

  Future<void> _openViewer(String ownerUid, String ownerName, List<Map<String, dynamic>> stories) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoryViewerScreen(stories: stories, ownerUid: ownerUid, ownerName: ownerName),
      ),
    );
    if (mounted) setState(() {}); // refresh seen/unseen rings after returning
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stories')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _storyService.feed(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          // Group flat docs by uid, each story carrying its own doc id,
          // preserving oldest-first order within each person's list (the
          // query itself is newest-first overall, so reverse each group).
          final byUid = <String, List<Map<String, dynamic>>>{};
          for (final data in snap.data!) {
            byUid.putIfAbsent(data['uid'] as String, () => []).insert(0, data);
          }
          final myStories = byUid.remove(_myUid) ?? const [];
          final otherUids = byUid.keys.toList()
            ..sort((a, b) {
              final aLatest = (byUid[a]!.last['createdAt'] as DateTime?) ?? DateTime(0);
              final bLatest = (byUid[b]!.last['createdAt'] as DateTime?) ?? DateTime(0);
              return bLatest.compareTo(aLatest);
            });

          return ListView(
            children: [
              ListTile(
                leading: Stack(
                  children: [
                    GradientRing(
                      ring: myStories.isNotEmpty,
                      child: UserAvatar(uid: _myUid, name: 'You', radius: 24),
                    ),
                    if (myStories.isEmpty)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: const Icon(Icons.add, size: 14, color: Colors.white),
                        ),
                      ),
                  ],
                ),
                title: const Text('Your story'),
                subtitle: Text(myStories.isEmpty ? 'Tap to post' : '${myStories.length} active'),
                onTap: myStories.isEmpty
                    ? _openComposer
                    : () => _openViewer(_myUid, 'You', myStories),
                onLongPress: _openComposer,
              ),
              if (otherUids.isNotEmpty) const Divider(height: 1),
              for (final uid in otherUids)
                FutureBuilder<String>(
                  future: _usernameFor(uid),
                  builder: (context, userSnap) {
                    final name = userSnap.data ?? '...';
                    final stories = byUid[uid]!;
                    final latestId = stories.last['id'] as String;
                    return FutureBuilder<bool>(
                      future: _storyService.haveIViewed(latestId),
                      builder: (context, seenSnap) {
                        final seen = seenSnap.data ?? false;
                        return ListTile(
                          leading: GradientRing(
                            seen: seen,
                            child: UserAvatar(uid: uid, name: name, radius: 22),
                          ),
                          title: Text(name),
                          subtitle: Text('${stories.length} ${stories.length == 1 ? 'story' : 'stories'}'),
                          onTap: () => _openViewer(uid, name, stories),
                        );
                      },
                    );
                  },
                ),
              if (otherUids.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No stories from your contacts yet')),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openComposer,
        child: const Icon(Icons.add_a_photo_outlined),
      ),
    );
  }
}
