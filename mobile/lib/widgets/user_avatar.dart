import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Looks up — and briefly remembers — other people's profile-photo URLs.
///
/// WHY THIS EXISTS (the "others can't see my profile photo" bug): the photo
/// URL was always saved correctly to `users/{uid}.photoUrl` and the upload
/// worked, but no screen except Edit profile ever READ that field for
/// anybody else — every chat row, contact row and chat header drew a letter
/// instead. This cache + [UserAvatar] is the one place that fixes that for
/// every screen at once.
///
/// Entries expire after a few minutes so a changed or removed photo shows up
/// for other people without a restart, without a Firestore read per row per
/// rebuild.
class AvatarCache {
  AvatarCache._();
  static final instance = AvatarCache._();

  static const _ttl = Duration(minutes: 5);
  final Map<String, _Entry> _entries = {};
  final Map<String, Future<String?>> _inflight = {};

  /// Whatever is cached right now (even if slightly old) — lets the avatar
  /// paint instantly instead of flashing a letter first.
  String? peek(String uid) => _entries[uid]?.url;

  Future<String?> photoUrlFor(String uid) {
    final e = _entries[uid];
    if (e != null && DateTime.now().difference(e.at) < _ttl) return Future.value(e.url);
    return _inflight[uid] ??= _fetch(uid).whenComplete(() => _inflight.remove(uid));
  }

  Future<String?> _fetch(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final url = doc.data()?['photoUrl'] as String?;
      _entries[uid] = _Entry(url, DateTime.now());
      return url;
    } catch (_) {
      // Offline / rule hiccup: keep showing the last known photo (or a letter).
      return _entries[uid]?.url;
    }
  }

  /// Call after I change or remove MY OWN photo so my screens update at once.
  void set(String uid, String? url) => _entries[uid] = _Entry(url, DateTime.now());

  void invalidate(String uid) => _entries.remove(uid);
}

class _Entry {
  final String? url;
  final DateTime at;
  _Entry(this.url, this.at);
}

/// A round avatar for a person: their profile photo if they have one,
/// otherwise the first letter of their name.
class UserAvatar extends StatefulWidget {
  final String uid;
  final String name;
  final double radius;
  final Color? backgroundColor;

  const UserAvatar({
    super.key,
    required this.uid,
    required this.name,
    this.radius = 20,
    this.backgroundColor,
  });

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  late Future<String?> _future = AvatarCache.instance.photoUrlFor(widget.uid);

  @override
  void didUpdateWidget(covariant UserAvatar old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) _future = AvatarCache.instance.photoUrlFor(widget.uid);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?';
    return FutureBuilder<String?>(
      future: _future,
      initialData: AvatarCache.instance.peek(widget.uid),
      builder: (context, snap) {
        final url = snap.data;
        final hasPhoto = url != null && url.isNotEmpty;
        return CircleAvatar(
          radius: widget.radius,
          backgroundColor: widget.backgroundColor ?? scheme.primaryContainer,
          // foregroundImage draws OVER the letter once it has loaded, and if
          // the download fails the letter simply stays visible.
          foregroundImage: hasPhoto ? NetworkImage(url!) : null,
          onForegroundImageError: hasPhoto ? (_, __) {} : null,
          child: Text(
            initial,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: widget.radius * 0.85,
              color: scheme.onPrimaryContainer,
            ),
          ),
        );
      },
    );
  }
}
