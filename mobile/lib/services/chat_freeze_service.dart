import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Feature: mutual timed block ("Pause this chat" in chat settings). Two
/// people choose a length of time (a preset or a custom pick) during
/// which NEITHER side can see the conversation in their chat list, and
/// NEITHER side can send to the other — fully mutual, unlike the
/// existing one-directional `blocks` collection (ModerationService),
/// which only ever stops the blocked person, not both.
///
/// Auto-lifts once [expiresAt] passes — checked client-side everywhere
/// it matters (ChatListScreen's list filter, MessageRelayService's send
/// check), the same "no server compute" pattern the rest of this app
/// already uses for disappearing messages (LocalMessageStore.purgeExpired).
/// The Firestore document isn't deleted the instant it expires — it just
/// stops counting as active the moment `expiresAt` is in the past,
/// wherever it's read.
class ChatFreezeService {
  ChatFreezeService._();
  static final instance = ChatFreezeService._();

  final _db = FirebaseFirestore.instance;
  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  /// Sorted so both people land on the SAME document id regardless of
  /// who's "first" — the actual content still records who started it via
  /// [initiatedBy].
  List<String> _sortedPair(String otherUid) => [_myUid, otherUid]..sort();
  String _pairKey(String otherUid) {
    final ids = _sortedPair(otherUid);
    return '${ids[0]}_${ids[1]}';
  }

  DocumentReference<Map<String, dynamic>> _freezeRef(String otherUid) =>
      _db.collection('timedFreezes').doc(_pairKey(otherUid));

  Future<void> freeze({required String otherUid, required Duration duration}) {
    final ids = _sortedPair(otherUid);
    return _freezeRef(otherUid).set({
      'participants': ids,
      'initiatedBy': _myUid,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(duration)),
    });
  }

  Future<void> endEarly(String otherUid) => _freezeRef(otherUid).delete();

  /// Null if there's no freeze, or it's expired but just hasn't been
  /// deleted yet — either way, "not currently frozen" from the caller's
  /// point of view.
  Future<DateTime?> activeFreezeExpiry(String otherUid) async {
    final snap = await _freezeRef(otherUid).get();
    return _activeExpiryFrom(snap.data());
  }

  Stream<DateTime?> watchActiveFreezeExpiry(String otherUid) {
    return _freezeRef(otherUid).snapshots().map((snap) => _activeExpiryFrom(snap.data()));
  }

  DateTime? _activeExpiryFrom(Map<String, dynamic>? data) {
    final expiresAt = (data?['expiresAt'] as Timestamp?)?.toDate();
    if (expiresAt == null || expiresAt.isBefore(DateTime.now())) return null;
    return expiresAt;
  }

  /// Every currently-active freeze involving this account, from either
  /// side — used by PausedChatsScreen, which is the one place someone can
  /// find and end a freeze early, since the conversation itself is
  /// otherwise completely hidden while paused. `participants` (an array
  /// containing exactly the two people involved) is what makes this a
  /// normal, rules-friendly `arrayContains` query instead of needing to
  /// read the whole collection.
  Stream<List<FrozenChatInfo>> watchMyActiveFreezes() {
    final myUid = _myUid;
    return _db
        .collection('timedFreezes')
        .where('participants', arrayContains: myUid)
        .snapshots()
        .map((snap) {
      final now = DateTime.now();
      return snap.docs
          .map((d) {
            final data = d.data();
            final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
            final participants = List<String>.from(data['participants'] ?? []);
            final otherUid = participants.firstWhere((u) => u != myUid, orElse: () => '');
            return (expiresAt: expiresAt, otherUid: otherUid, initiatedByMe: data['initiatedBy'] == myUid);
          })
          .where((f) => f.expiresAt != null && f.expiresAt!.isAfter(now) && f.otherUid.isNotEmpty)
          .map((f) => FrozenChatInfo(otherUid: f.otherUid, expiresAt: f.expiresAt!, initiatedByMe: f.initiatedByMe))
          .toList();
    });
  }
}

class FrozenChatInfo {
  final String otherUid;
  final DateTime expiresAt;
  final bool initiatedByMe;
  const FrozenChatInfo({required this.otherUid, required this.expiresAt, required this.initiatedByMe});
}
