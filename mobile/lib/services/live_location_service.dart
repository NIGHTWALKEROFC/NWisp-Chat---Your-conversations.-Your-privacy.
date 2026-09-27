import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'message_relay_service.dart';

/// Feature: live location sharing — "share for 15 min / 1 hour / 8 hours",
/// not just a single dropped pin. See firestore.rules' liveLocations/{id}
/// block for the full explanation of why this uses plain Firestore for the
/// moving coordinates (like this app's existing typing indicators) instead
/// of the Signal-encrypted message relay — the SHARE ITSELF (who, until
/// when) is still sent as a normal end-to-end encrypted chat message; only
/// the position updates that follow are not.
///
/// ⚠️ Background limitation (read before assuming this "just works" with
/// the screen off for the full duration): true always-on background
/// tracking needs a dedicated Android foreground Service written in native
/// Kotlin, which this app does not have. What's here updates reliably
/// while the app is open or briefly backgrounded (Android's own grace
/// period), consistent with ACCESS_BACKGROUND_LOCATION's real limits
/// without that extra native service — see the manifest comment next to
/// that permission. A share can therefore go quiet before its chosen time
/// is up if the phone sits backgrounded for a while; the bubble always
/// shows the actual last-updated time, never a false "live" state past
/// that point (see [LiveShare.isStale]).
class LiveLocationService {
  LiveLocationService._();

  static final _db = FirebaseFirestore.instance;
  static const _collection = 'liveLocations';

  /// How often a fresh position is written, and the minimum distance
  /// (meters) required to bother writing one sooner than that — keeps this
  /// from hammering Firestore if someone's standing still.
  static const _updateInterval = Duration(seconds: 20);
  static const _minDistanceMeters = 15;

  static StreamSubscription<Position>? _positionSub;
  static Timer? _expiryTimer;
  static String? _activeShareId;

  static String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception('Not signed in');
    return uid;
  }

  /// Call once at app startup (see main.dart). If this device had an
  /// active share still running when the app was last closed, this picks
  /// the position stream back up instead of leaving the Firestore doc
  /// silently going stale — the recipient's bubble would otherwise just
  /// sit on the last position from before the app closed with no
  /// indication of why.
  static Future<void> resumeActiveShareIfAny() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;
    try {
      final snap = await _db.collection(_collection).where('senderUid', isEqualTo: myUid).where('stopped', isEqualTo: false).get();
      for (final doc in snap.docs) {
        final expiresAt = (doc.data()['expiresAt'] as Timestamp?)?.toDate();
        if (expiresAt != null && expiresAt.isAfter(DateTime.now())) {
          await _beginPositionUpdates(doc.id, expiresAt);
          break; // only one share is ever active at a time — see startSharing
        }
      }
    } catch (_) {
      // Best-effort — a normal app start shouldn't fail over this.
    }
  }

  /// Whether Location Services are on and this app has permission to read
  /// them "while in use" at minimum. Call before [startSharing] so the
  /// caller can show its own explanation UI first if this comes back
  /// false, rather than a bare OS permission dialog with no context.
  static Future<bool> hasUsablePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final perm = await Geolocator.checkPermission();
    return perm == LocationPermission.always || perm == LocationPermission.whileInUse;
  }

  /// Requests location permission, "while in use" first and then, only if
  /// that's granted, "always" (Android requires them to be asked for in
  /// that order — see the manifest comment on ACCESS_BACKGROUND_LOCATION).
  /// Returns true once at least "while in use" is granted (good enough to
  /// start sharing — see this class's background-limitation note above for
  /// why "always" isn't a hard requirement).
  static Future<bool> requestPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return false;
    if (perm == LocationPermission.whileInUse) {
      // Best-effort upgrade — a "no" here still leaves whileInUse active,
      // which is enough to proceed.
      await Geolocator.requestPermission();
    }
    return true;
  }

  /// Starts a new share: creates the Firestore doc, sends the chat message
  /// that shows up as the live-location bubble (see
  /// ChatDetailScreen/LiveLocationBubble), and begins pushing position
  /// updates. Only one share can be active per device at a time — starting
  /// a new one stops whatever was running before, same as most apps that
  /// have this feature.
  static Future<void> startSharing({
    required String conversationId,
    required String recipientUid,
    required Duration duration,
  }) async {
    await stopActiveShare();

    final myUid = _myUid;
    final shareId = _db.collection(_collection).doc().id;
    final startedAt = DateTime.now();
    final expiresAt = startedAt.add(duration);

    final first = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

    await _db.collection(_collection).doc(shareId).set({
      'senderUid': myUid,
      'recipientUid': recipientUid,
      'conversationId': conversationId,
      'startedAt': Timestamp.fromDate(startedAt),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'lat': first.latitude,
      'lng': first.longitude,
      'accuracy': first.accuracy,
      'updatedAt': FieldValue.serverTimestamp(),
      'stopped': false,
    });

    // Feature: the share's existence travels as an ordinary, end-to-end
    // encrypted chat message — see this class's doc comment above for why
    // only the coordinates that follow don't. ttlHours: 0 (never expires
    // as a MESSAGE) regardless of the share's own duration; the bubble
    // itself shows "Live location ended" once expired rather than the
    // message disappearing.
    await MessageRelayService.sendMessage(
      conversationId: conversationId,
      recipientUid: recipientUid,
      text: jsonEncode({'shareId': shareId, 'expiresAt': expiresAt.toIso8601String()}),
      messageType: 'live_location',
      ttlHours: 0,
    );

    await _beginPositionUpdates(shareId, expiresAt);
  }

  static Future<void> _beginPositionUpdates(String shareId, DateTime expiresAt) async {
    _activeShareId = shareId;
    await _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: _minDistanceMeters),
    ).listen((position) {
      _db.collection(_collection).doc(shareId).update({
        'lat': position.latitude,
        'lng': position.longitude,
        'accuracy': position.accuracy,
        'updatedAt': FieldValue.serverTimestamp(),
      }).catchError((Object _) {});
    });

    _expiryTimer?.cancel();
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) {
      await stopActiveShare();
    } else {
      _expiryTimer = Timer(remaining, () => stopActiveShare());
    }
  }

  /// Manually ends whichever share this device is currently sending (if
  /// any) — the "Stop sharing" action in the bubble/chat. Marks the
  /// Firestore doc stopped rather than deleting it, so the recipient's
  /// bubble can show exactly when/where sharing ended instead of the doc
  /// just vanishing out from under their open screen.
  static Future<void> stopActiveShare() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    await _positionSub?.cancel();
    _positionSub = null;
    final id = _activeShareId;
    _activeShareId = null;
    if (id == null) return;
    try {
      await _db.collection(_collection).doc(id).update({'stopped': true, 'stoppedAt': FieldValue.serverTimestamp()});
    } catch (_) {}
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchShare(String shareId) {
    return _db.collection(_collection).doc(shareId).snapshots();
  }
}

/// Parsed view of a liveLocations/{shareId} document, for the bubble and
/// full-screen map widgets to build from without each re-deriving these
/// same checks.
class LiveShare {
  final String senderUid;
  final String recipientUid;
  final double? lat;
  final double? lng;
  final double? accuracy;
  final DateTime? updatedAt;
  final DateTime expiresAt;
  final bool stopped;

  const LiveShare({
    required this.senderUid,
    required this.recipientUid,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.updatedAt,
    required this.expiresAt,
    required this.stopped,
  });

  factory LiveShare.fromDoc(Map<String, dynamic> data) => LiveShare(
        senderUid: data['senderUid'] as String,
        recipientUid: data['recipientUid'] as String,
        lat: (data['lat'] as num?)?.toDouble(),
        lng: (data['lng'] as num?)?.toDouble(),
        accuracy: (data['accuracy'] as num?)?.toDouble(),
        updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
        expiresAt: (data['expiresAt'] as Timestamp).toDate(),
        stopped: data['stopped'] as bool? ?? false,
      );

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// True once sharing has stopped OR its time is up — either way, the
  /// bubble should stop showing a "Live" pulse and switch to "ended".
  bool get hasEnded => stopped || isExpired;

  /// A share that's technically still active but hasn't had a fresh
  /// position in a while (see this file's background-limitation note) —
  /// shown as "may be out of date" instead of a confidently-wrong "Live".
  bool get isStale => !hasEnded && updatedAt != null && DateTime.now().difference(updatedAt!) > const Duration(minutes: 3);

  Duration get remaining => expiresAt.difference(DateTime.now());
}
