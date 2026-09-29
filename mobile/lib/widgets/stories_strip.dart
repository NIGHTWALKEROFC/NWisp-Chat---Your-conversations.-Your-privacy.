import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../screens/stories/story_composer_screen.dart';
import '../screens/stories/story_viewer_screen.dart';
import '../services/story_service.dart';
import 'nwisp_ui.dart';
import 'user_avatar.dart';

/// The row of round story avatars at the top of the chat list ("My Story",
/// then everyone with an active story). Uses the exact same feed and
/// seen/unseen logic as the Stories tab (StoriesTabScreen) — it only shows
/// it in a compact horizontal form. Hidden completely when nobody has a
/// story and you have none of your own, so the chat list isn't pushed down
/// for no reason... except your own "My Story" bubble, which is always
/// there so posting one is a single tap away.
class StoriesStrip extends StatefulWidget {
  const StoriesStrip({super.key});

  @override
  State<StoriesStrip> createState() => _StoriesStripState();
}

class _StoriesStripState extends State<StoriesStrip> {
  final _storyService = StoryService.instance;
  final Map<String, String> _usernameCache = {};

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  Future<void> _openViewer(String ownerUid, String ownerName, List<Map<String, dynamic>> stories) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoryViewerScreen(stories: stories, ownerUid: ownerUid, ownerName: ownerName),
      ),
    );
    if (mounted) setState(() {}); // refresh seen/unseen rings
  }

  Future<void> _openComposer() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const StoryComposerScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final myUid = _myUid;
    if (myUid == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _storyService.feedStories(),
      builder: (context, snap) {
        // Same grouping as StoriesTabScreen: newest-first query, reversed
        // per person so each list is oldest-first.
        final byUid = <String, List<Map<String, dynamic>>>{};
        if (snap.hasData) {
          for (final doc in snap.data!.docs) {
            final data = {...doc.data(), 'id': doc.id};
            byUid.putIfAbsent(data['uid'] as String, () => []).insert(0, data);
          }
        }
        final myStories = byUid.remove(myUid) ?? const <Map<String, dynamic>>[];
        final otherUids = byUid.keys.toList()
          ..sort((a, b) {
            final aLatest = (byUid[a]!.last['createdAt'] as Timestamp?)?.toDate() ?? DateTime(0);
            final bLatest = (byUid[b]!.last['createdAt'] as Timestamp?)?.toDate() ?? DateTime(0);
            return bLatest.compareTo(aLatest);
          });

        return SizedBox(
          height: 96,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            children: [
              _StoryBubble(
                label: 'My Story',
                onTap: myStories.isEmpty ? _openComposer : () => _openViewer(myUid, 'You', myStories),
                onLongPress: _openComposer,
                avatar: Stack(
                  children: [
                    GradientRing(
                      ring: myStories.isNotEmpty,
                      child: UserAvatar(uid: myUid, name: 'You', radius: 25),
                    ),
                    if (myStories.isEmpty)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: scheme.primary,
                          child: const Icon(Icons.add, size: 14, color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              for (final uid in otherUids)
                FutureBuilder<String>(
                  future: _usernameFor(uid),
                  builder: (context, userSnap) {
                    final name = userSnap.data ?? '…';
                    final stories = byUid[uid]!;
                    final latestId = stories.last['id'] as String;
                    return FutureBuilder<bool>(
                      future: _storyService.haveIViewed(latestId),
                      builder: (context, seenSnap) {
                        final seen = seenSnap.data ?? false;
                        return _StoryBubble(
                          label: name,
                          onTap: () => _openViewer(uid, name, stories),
                          avatar: GradientRing(
                            seen: seen,
                            child: UserAvatar(uid: uid, name: name, radius: 25),
                          ),
                        );
                      },
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StoryBubble extends StatelessWidget {
  final String label;
  final Widget avatar;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _StoryBubble({required this.label, required this.avatar, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 66,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              avatar,
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
