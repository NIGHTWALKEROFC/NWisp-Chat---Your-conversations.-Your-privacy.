import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'message_relay_service.dart';

/// Feature: traffic pattern camouflage. Optional, off by default (both
/// globally and per-chat) — an observer who can see `message_relay` row
/// TIMING and COUNT but never their content (they're end-to-end
/// encrypted regardless of this feature) can otherwise still learn
/// something from the pattern itself: when you're active, roughly how
/// often you message someone, and roughly how long each message is.
/// This feature blurs both signals:
///
///  1. MESSAGE PADDING (see MessageRelayService._padPayload) — text
///     messages sent in a camouflage-enabled chat are padded, inside the
///     end-to-end-encrypted payload, to the next fixed size bucket
///     before encryption, so their ciphertext length only reveals which
///     bucket a message fell into, not its exact length. Only applies to
///     the text content itself — media (photos/videos/voice) already
///     varies enormously in size and padding it to match would waste a
///     lot of bandwidth for little benefit, so it's left as-is.
///
///  2. DUMMY TRAFFIC (see _maybeSendDecoy below) — while this device is
///     running, at randomized intervals, a real, fully end-to-end
///     encrypted "decoy" message is sent to one of your camouflage-
///     enabled 1:1 chats. It's indistinguishable in shape (same table,
///     same columns, same message_type) from an ordinary message to
///     anyone who can't decrypt it — only the recipient's own device can
///     tell, and it silently discards it (see
///     MessageRelayService._handleRow's decoy check): never shown, never
///     notified, never counted as unread.
///
/// HONEST LIMITS — read before relying on this for anything serious:
///  - Decoys only send while the app is actually running on this device
///    (foreground or backgrounded-but-alive) — there is no persistent
///    background service keeping them going while the app is fully
///    closed or the phone is asleep for long stretches. An observer
///    watching over a long enough window can likely still tell when the
///    app itself isn't running.
///  - This defends against someone who can see Supabase's `message_relay`
///    table shape/timing but NOT its contents. It does nothing against
///    someone who already has your Signal Protocol keys, and it doesn't
///    hide THAT you're using NWisp at all (network-level VPN/Tor-style
///    hiding is outside what an app-level feature like this can do).
///  - Costs real battery and data whenever it's on — see the warning
///    shown before enabling it in Settings > Privacy.
class TrafficCamouflageService {
  TrafficCamouflageService._();
  static final instance = TrafficCamouflageService._();

  final _db = FirebaseFirestore.instance;
  final _rng = Random.secure();

  /// Group conversation ids are always "group_<uuid>" — matches
  /// MessageRelayService's own constant. Decoy traffic only targets 1:1
  /// chats in this pass; group fan-out isn't covered.
  static const _groupIdPrefix = 'group_';

  bool _globalEnabled = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  Timer? _decoyTimer;
  final Map<String, bool?> _overrideCache = {};

  bool get globalEnabled => _globalEnabled;

  DocumentReference<Map<String, dynamic>> _privateProfileRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('profile');

  /// Call once after sign-in (see main.dart, alongside
  /// MessageRelayService.start()) and again after sign-out via [stop].
  void start(String uid) {
    _profileSub?.cancel();
    _profileSub = _privateProfileRef(uid).snapshots().listen((snap) {
      _globalEnabled = (snap.data()?['trafficCamouflageGlobal'] as bool?) ?? false;
    }, onError: (_) {});
    _scheduleNextDecoy(uid);
  }

  void stop() {
    _profileSub?.cancel();
    _decoyTimer?.cancel();
    _profileSub = null;
    _decoyTimer = null;
    _overrideCache.clear();
  }

  Future<void> setGlobalEnabled(String uid, bool enabled) =>
      _privateProfileRef(uid).set({'trafficCamouflageGlobal': enabled}, SetOptions(merge: true));

  /// null = "use the app default" (the global toggle above); true/false =
  /// an explicit override for this one chat, same three-state pattern as
  /// this app's existing per-chat auto-delete override.
  Future<bool?> getChatOverride(String conversationId) async {
    final doc = await _db.collection('conversations').doc(conversationId).get();
    return doc.data()?['trafficCamouflageOverride'] as bool?;
  }

  Future<void> setChatOverride(String conversationId, bool? enabled) async {
    await _db.collection('conversations').doc(conversationId).set({'trafficCamouflageOverride': enabled}, SetOptions(merge: true));
    _overrideCache[conversationId] = enabled;
  }

  /// Whether padding/decoys should apply to [conversationId] right now.
  /// Cached in memory per conversation for the life of the app session —
  /// the override rarely changes mid-conversation, and this is called on
  /// every single text send, so avoiding a Firestore round trip each
  /// time matters more here than picking up a same-session change from
  /// another device instantly (there's only ever one active device for
  /// chat anyway — see DeviceSessionService's own notes on that).
  Future<bool> isEffectiveEnabledForChat(String conversationId) async {
    if (!_overrideCache.containsKey(conversationId)) {
      try {
        _overrideCache[conversationId] = await getChatOverride(conversationId);
      } catch (_) {
        _overrideCache[conversationId] = null; // fail open to the global default rather than throwing mid-send
      }
    }
    return _overrideCache[conversationId] ?? _globalEnabled;
  }

  // -------------------------------------------------------------------
  // Decoy scheduling
  // -------------------------------------------------------------------

  void _scheduleNextDecoy(String uid) {
    if (FirebaseAuth.instance.currentUser?.uid != uid) return; // signed out meanwhile
    // Randomized interval (45s-3m45s) rather than a fixed cadence — a
    // perfectly regular "one decoy every N seconds" heartbeat would
    // itself be a distinguishing pattern. Also comfortably under the
    // message_relay rate limit (30 inserts/10s — see
    // 0001_message_relay_rate_limit.sql), which real messages from the
    // same device also share.
    final seconds = 45 + _rng.nextInt(180);
    _decoyTimer = Timer(Duration(seconds: seconds), () async {
      await _maybeSendDecoy(uid);
      _scheduleNextDecoy(uid);
    });
  }

  Future<void> _maybeSendDecoy(String uid) async {
    try {
      if (!_globalEnabled && !(await _anyPerChatOverrideOn(uid))) return;
      final candidates = await _eligibleConversations(uid);
      if (candidates.isEmpty) return;
      candidates.shuffle(_rng);
      final target = candidates.first;
      await MessageRelayService.sendDecoyMessage(conversationId: target.$1, recipientUid: target.$2);
    } catch (_) {
      // Best-effort and invisible either way — a failed decoy send is
      // never surfaced to the person, same as a failed decoy simply not
      // happening this round.
    }
  }

  /// Cheap early-out so a fresh sign-in with the feature entirely off
  /// (the common case) doesn't run the full conversations query below
  /// every couple of minutes for nothing.
  Future<bool> _anyPerChatOverrideOn(String uid) async {
    if (_globalEnabled) return true;
    return _overrideCache.values.any((v) => v == true);
  }

  Future<List<(String, String)>> _eligibleConversations(String uid) async {
    final snap = await _db.collection('conversations').where('participants', arrayContains: uid).get();
    final result = <(String, String)>[];
    for (final doc in snap.docs) {
      if (doc.id.startsWith(_groupIdPrefix)) continue;
      final override = doc.data()['trafficCamouflageOverride'] as bool?;
      _overrideCache[doc.id] = override;
      final effective = override ?? _globalEnabled;
      if (!effective) continue;
      final participants = List<String>.from(doc.data()['participants'] ?? const []);
      final peer = participants.firstWhere((p) => p != uid, orElse: () => '');
      if (peer.isEmpty) continue;
      result.add((doc.id, peer));
    }
    return result;
  }
}
