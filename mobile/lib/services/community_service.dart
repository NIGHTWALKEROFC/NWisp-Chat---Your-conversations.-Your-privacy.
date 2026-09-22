import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'group_service.dart';
import 'media_service.dart';

/// The ready-made topics a community can pick from (optional).
const List<String> kCommunityCategories = [
  'Local area',
  'Education',
  'Jobs & careers',
  'Health & wellness',
  'Sports & fitness',
  'Buy & sell',
  'Tech',
  'News & updates',
  'Help & support',
  'Arts & culture',
  'Food',
  'Travel',
  'Faith & spirituality',
  'Other',
];

/// Optional "where is this community" — every level may be left empty.
class CommunityLocation {
  final String? country;
  final String? state;
  final String? district;

  const CommunityLocation({this.country, this.state, this.district});

  bool get isEmpty => _blank(country) && _blank(state) && _blank(district);

  /// "Ernakulam, Kerala, India" — only the parts that were filled in.
  String get label => [district, state, country].where((e) => !_blank(e)).map((e) => e!.trim()).join(', ');

  CommunityLocation copyWith({String? country, String? state, String? district, bool clearState = false, bool clearDistrict = false}) {
    return CommunityLocation(
      country: country ?? this.country,
      state: clearState ? null : (state ?? this.state),
      district: clearDistrict ? null : (district ?? this.district),
    );
  }

  static bool _blank(String? s) => s == null || s.trim().isEmpty;

  /// Lower-cased, trimmed form used for matching in filters, so "kerala",
  /// "Kerala " and "KERALA" all find the same communities.
  static String key(String s) => s.trim().toLowerCase();
}

/// One entry in the public Community directory (`communities/{groupId}`).
/// The doc id is the SAME id as the community's group document, which is
/// where its members and its encrypted chat actually live.
class CommunityListing {
  final String id;
  final String name;
  final String description;
  final String? category;
  final String rules;
  final String? avatarUrl;
  final String ownerId;
  final CommunityLocation location;
  final int memberCount;
  final int maxMembers;
  final bool onlyAdminsCanSend;
  final bool isActive;
  final DateTime createdAt;

  const CommunityListing({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.rules,
    required this.avatarUrl,
    required this.ownerId,
    required this.location,
    required this.memberCount,
    required this.maxMembers,
    required this.onlyAdminsCanSend,
    required this.isActive,
    required this.createdAt,
  });

  factory CommunityListing.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    String? s(String k) {
      final v = d[k] as String?;
      return (v == null || v.trim().isEmpty) ? null : v;
    }

    return CommunityListing(
      id: doc.id,
      name: (d['name'] as String?) ?? 'Community',
      description: (d['description'] as String?) ?? '',
      category: s('category'),
      rules: (d['rules'] as String?) ?? '',
      avatarUrl: s('avatarUrl'),
      ownerId: (d['ownerId'] as String?) ?? '',
      location: CommunityLocation(country: s('country'), state: s('state'), district: s('district')),
      memberCount: (d['memberCount'] as num?)?.toInt() ?? 0,
      maxMembers: (d['maxMembers'] as num?)?.toInt() ?? CommunityService.defaultMaxMembers,
      onlyAdminsCanSend: (d['onlyAdminsCanSend'] as bool?) ?? false,
      isActive: (d['isActive'] as bool?) ?? true,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  bool get isFull => memberCount >= maxMembers;
}

/// Public communities — anyone signed in can find and join one, unlike a
/// normal group (which is invisible to everyone who isn't in it).
///
/// TWO documents per community:
///  * `groups/{id}` — the private part: members, admins, bans. Exactly the
///    same document a normal group uses, so the whole existing group chat
///    (encryption, reactions, receipts, mute, leave…) works unchanged.
///  * `communities/{id}` — the PUBLIC listing everyone can read: name,
///    description, category, rules, optional location, member count.
///
/// MESSAGES ARE NEVER STORED ON A SERVER. They travel exactly like group
/// messages already do (one encrypted copy per member, through the
/// temporary relay) and are saved only on each member's phone. That
/// per-member encryption is also why a community has a small member cap.
class CommunityService {
  CommunityService._();
  static final instance = CommunityService._();

  static const int defaultMaxMembers = 50;
  static const List<int> maxMembersOptions = [25, 50, 100];

  final _db = FirebaseFirestore.instance;

  String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  CollectionReference<Map<String, dynamic>> get _listings => _db.collection('communities');

  /// Loads listings, optionally narrowed by place / topic. Only equality
  /// filters are sent to Firestore (no ordering when filtering), so this
  /// needs NO extra database index; sorting and text search happen on the
  /// phone. Capped at 150 results.
  Future<List<CommunityListing>> fetch({CommunityLocation? location, String? category}) async {
    Query<Map<String, dynamic>> q = _listings;
    var filtered = false;
    final loc = location;
    if (loc != null) {
      if (!_blank(loc.country)) {
        q = q.where('countryKey', isEqualTo: CommunityLocation.key(loc.country!));
        filtered = true;
      }
      if (!_blank(loc.state)) {
        q = q.where('stateKey', isEqualTo: CommunityLocation.key(loc.state!));
        filtered = true;
      }
      if (!_blank(loc.district)) {
        q = q.where('districtKey', isEqualTo: CommunityLocation.key(loc.district!));
        filtered = true;
      }
    }
    if (!_blank(category)) {
      q = q.where('category', isEqualTo: category);
      filtered = true;
    }
    if (!filtered) q = q.orderBy('createdAt', descending: true);
    final snap = await q.limit(150).get();
    return snap.docs.map(CommunityListing.fromDoc).where((c) => c.isActive).toList();
  }

  Stream<CommunityListing?> listingStream(String id) =>
      _listings.doc(id).snapshots().map((d) => d.exists ? CommunityListing.fromDoc(d) : null);

  Future<String> create({
    required String name,
    required String description,
    String? category,
    String rules = '',
    CommunityLocation location = const CommunityLocation(),
    File? avatarFile,
    bool onlyAdminsCanSend = false,
    int maxMembers = defaultMaxMembers,
  }) async {
    final myUid = _myUid;
    final groupId = GroupService.instance.newGroupId();
    final cleanName = name.trim();
    String? avatarUrl;
    if (avatarFile != null) avatarUrl = await MediaService.uploadGroupAvatar(avatarFile, groupId);

    await GroupService.instance.createGroup(
      groupId: groupId,
      name: cleanName,
      avatarUrl: avatarUrl,
      memberUids: const [],
      onlyAdminsCanSend: onlyAdminsCanSend,
      isCommunity: true,
      maxMembers: maxMembers,
      description: description,
    );
    try {
      await _listings.doc(groupId).set({
        'name': cleanName,
        'nameLower': cleanName.toLowerCase(),
        'description': description.trim(),
        'category': category,
        'rules': rules.trim(),
        'avatarUrl': avatarUrl,
        'ownerId': myUid,
        ..._locationFields(location),
        'memberCount': 1,
        'maxMembers': maxMembers,
        'onlyAdminsCanSend': onlyAdminsCanSend,
        'isActive': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Don't leave a half-made, unlisted community behind.
      try {
        await _db.collection('groups').doc(groupId).delete();
      } catch (_) {}
      rethrow;
    }
    return groupId;
  }

  /// Admin edit of an existing community (name, description, topic, rules,
  /// place, size, who can post) — updates the private group document and
  /// the public listing together.
  Future<void> update({
    required String groupId,
    required String name,
    required String description,
    String? category,
    String rules = '',
    CommunityLocation location = const CommunityLocation(),
    bool onlyAdminsCanSend = false,
    int maxMembers = defaultMaxMembers,
  }) async {
    final cleanName = name.trim();
    await _db.collection('groups').doc(groupId).update({
      'name': cleanName,
      'description': description.trim(),
      'onlyAdminsCanSend': onlyAdminsCanSend,
      'maxMembers': maxMembers,
    });
    await _listings.doc(groupId).update({
      'name': cleanName,
      'nameLower': cleanName.toLowerCase(),
      'description': description.trim(),
      'category': category,
      'rules': rules.trim(),
      ..._locationFields(location),
      'onlyAdminsCanSend': onlyAdminsCanSend,
      'maxMembers': maxMembers,
    });
  }

  Map<String, dynamic> _locationFields(CommunityLocation l) => {
        'country': _blank(l.country) ? null : l.country!.trim(),
        'state': _blank(l.state) ? null : l.state!.trim(),
        'district': _blank(l.district) ? null : l.district!.trim(),
        'countryKey': _blank(l.country) ? null : CommunityLocation.key(l.country!),
        'stateKey': _blank(l.state) ? null : CommunityLocation.key(l.state!),
        'districtKey': _blank(l.district) ? null : CommunityLocation.key(l.district!),
      };

  /// Joins an open community as myself. The database rules do the real
  /// checking (not banned, not full, community really is open) — if any of
  /// those fail this throws and nothing changes.
  Future<void> join(String groupId) async {
    await _db.collection('groups').doc(groupId).update({
      'members': FieldValue.arrayUnion([_myUid]),
    });
    // Public member counter — best-effort, never blocks the join.
    _listings.doc(groupId).update({'memberCount': FieldValue.increment(1)}).catchError((_) {});
  }

  /// Leaves a community. If I was the very last member the public listing
  /// is removed too; otherwise the counter just goes down by one.
  Future<void> leave(String groupId) async {
    var wasLast = false;
    try {
      final snap = await _db.collection('groups').doc(groupId).get();
      wasLast = List<String>.from(snap.data()?['members'] ?? const []).length <= 1;
    } catch (_) {}
    await GroupService.instance.leaveGroup(groupId);
    if (wasLast) {
      _listings.doc(groupId).delete().catchError((_) {});
    } else {
      _listings.doc(groupId).update({'memberCount': FieldValue.increment(-1)}).catchError((_) {});
    }
  }

  /// Admins only: after removing / banning people, set the public member
  /// counter back to the true number.
  Future<void> syncMemberCount(String groupId, int actual) async {
    try {
      await _listings.doc(groupId).update({'memberCount': actual});
    } catch (_) {}
  }

  bool _blank(String? s) => s == null || s.trim().isEmpty;
}
