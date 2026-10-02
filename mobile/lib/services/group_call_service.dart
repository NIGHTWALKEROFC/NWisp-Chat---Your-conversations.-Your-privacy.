import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'call_log_service.dart';
import 'call_quality_service.dart';
import 'call_recording_watcher.dart';
import 'call_service.dart';
import 'incoming_call_notifier.dart';

/// Feature: group voice calls (audio only).
///
/// Up to [maxParticipants] people talk at once. Every pair of people is
/// connected directly (a "mesh"), which is fine for audio — each connection
/// is only about 30 kbit/s — and needs no media server, so it costs nothing.
/// The phones swap their small WebRTC "signalling" notes through Firestore
/// (groupCalls/{id}/signals); audio never touches Firestore or Supabase.
///
/// Who offers to whom is decided by a fixed rule (the larger user id makes
/// the offer), so two people joining at the same moment can never both wait
/// for the other.
class GroupCallService {
  GroupCallService._();
  static final instance = GroupCallService._();

  static const int maxParticipants = 6;

  final _db = FirebaseFirestore.instance;
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  final ValueNotifier<IncomingGroupCall?> incoming = ValueNotifier<IncomingGroupCall?>(null);
  StreamSubscription? _sub;
  GroupCallSession? _active;
  GroupCallSession? get active => _active;
  final Set<String> _dismissed = {};
  String? handledCallId;
  final Map<String, String> _names = {};

  Future<String> nameOf(String uid) async {
    final cached = _names[uid];
    if (cached != null) return cached;
    try {
      final d = await _db.collection('users').doc(uid).get();
      final n = (d.data()?['username'] as String?) ?? 'Member';
      _names[uid] = n;
      return n;
    } catch (_) {
      return 'Member';
    }
  }

  void startListening() {
    final uid = _myUid;
    if (uid == null) return;
    _sub?.cancel();
    _sub = _db.collection('groupCalls').where('members', arrayContains: uid).snapshots().listen((snapAll) {
      final now = DateTime.now();
      // Only still-running calls matter (filtered here, not in the query, so
      // Firestore needs no extra index).
      final active = snapAll.docs.where((d) => d.data()['status'] == 'active').toList();
      final snap = (docs: active);
      for (final d in snap.docs) {
        final data = d.data();
        final created = (data['createdAt'] as Timestamp?)?.toDate();
        final joined = List<String>.from(data['joined'] ?? const []);
        if (data['starterUid'] == uid || joined.contains(uid)) continue;
        if (created != null && now.difference(created) > const Duration(seconds: 60)) continue;
        if (_dismissed.contains(d.id) || _active != null) continue;
        if (incoming.value?.callId == d.id) return;
        incoming.value = IncomingGroupCall(
          callId: d.id,
          groupId: data['groupId'] as String,
          groupName: (data['groupName'] as String?) ?? 'Group',
          starterUid: data['starterUid'] as String,
          starterName: (data['starterName'] as String?) ?? 'Someone',
        );
        return;
      }
      if (incoming.value != null && !snap.docs.any((d) => d.id == incoming.value!.callId)) {
        incoming.value = null;
      }
    }, onError: (_) {});
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
    incoming.value = null;
  }

  /// A call already going on in [groupId] that can be joined, if any.
  Future<IncomingGroupCall?> ongoingIn(String groupId) async {
    final uid = _myUid;
    if (uid == null) return null;
    try {
      final snap = await _db.collection('groupCalls').where('members', arrayContains: uid).get();
      for (final d in snap.docs) {
        final data = d.data();
        if (data['status'] != 'active' || data['groupId'] != groupId) continue;
        final joined = List<String>.from(data['joined'] ?? const []);
        final created = (data['createdAt'] as Timestamp?)?.toDate();
        // A call nobody is in, or one that is many hours old, is a leftover.
        if (joined.isEmpty) continue;
        if (created != null && DateTime.now().difference(created) > const Duration(hours: 6)) continue;
        return IncomingGroupCall(
          callId: d.id,
          groupId: groupId,
          groupName: (data['groupName'] as String?) ?? 'Group',
          starterUid: data['starterUid'] as String,
          starterName: (data['starterName'] as String?) ?? 'Someone',
        );
      }
    } catch (_) {}
    return null;
  }

  Future<GroupCallSession> start({
    required String groupId,
    required String groupName,
    required List<String> memberUids,
    required String myName,
  }) async {
    final uid = _myUid;
    if (uid == null) throw StateError('Not signed in.');
    if (_active != null) throw StateError('You are already in a call.');
    if (CallService.instance.active != null) throw StateError('You are already in a call.');
    final ref = _db.collection('groupCalls').doc();
    final s = GroupCallSession._(ref: ref, myUid: uid, groupId: groupId, groupName: groupName, starterUid: uid);
    _register(s);
    await s._begin(create: {
      'groupId': groupId,
      'groupName': groupName,
      'starterUid': uid,
      'starterName': myName,
      'members': memberUids,
      'joined': [uid],
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
      'expireAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 1))),
    });
    unawaited(_pushRing(ref.id));
    await CallLogService.instance.logGroup(
      callId: ref.id,
      groupId: groupId,
      starterUid: uid,
      text: 'You started a group voice call',
    );
    return s;
  }

  Future<GroupCallSession> join(IncomingGroupCall call) async {
    final uid = _myUid;
    if (uid == null) throw StateError('Not signed in.');
    if (_active != null || CallService.instance.active != null) throw StateError('You are already in a call.');
    handledCallId = call.callId;
    IncomingCallNotifier.cancelRing();
    incoming.value = null;
    final ref = _db.collection('groupCalls').doc(call.callId);
    final s = GroupCallSession._(ref: ref, myUid: uid, groupId: call.groupId, groupName: call.groupName, starterUid: call.starterUid);
    _register(s);
    await s._begin();
    return s;
  }

  Future<void> ignore(IncomingGroupCall call) async {
    handledCallId = call.callId;
    _dismissed.add(call.callId);
    IncomingCallNotifier.cancelRing();
    IncomingCallNotifier.showOverLockScreen(false);
    incoming.value = null;
    await CallLogService.instance.logGroup(
      callId: call.callId,
      groupId: call.groupId,
      starterUid: call.starterUid,
      text: 'Missed group voice call',
    );
  }

  void _register(GroupCallSession s) {
    _active = s;
    s._onClosed = () {
      if (identical(_active, s)) _active = null;
    };
  }

  Future<void> _pushRing(String callId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();
      final base = const String.fromEnvironment('SUPABASE_URL');
      await http
          .post(
            Uri.parse('$base/functions/v1/send-call-push'),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'kind': 'group_call', 'callId': callId}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}

class IncomingGroupCall {
  final String callId;
  final String groupId;
  final String groupName;
  final String starterUid;
  final String starterName;
  IncomingGroupCall({
    required this.callId,
    required this.groupId,
    required this.groupName,
    required this.starterUid,
    required this.starterName,
  });
}

class _Peer {
  RTCPeerConnection? pc;
  bool connected = false;
  bool remoteSet = false;
  final List<RTCIceCandidate> pending = [];
}

/// One live group call. Screens listen to it (it is a ChangeNotifier).
class GroupCallSession extends ChangeNotifier {
  final DocumentReference<Map<String, dynamic>> ref;
  final String myUid;
  final String groupId;
  final String groupName;
  final String starterUid;
  VoidCallback? _onClosed;

  GroupCallSession._({
    required this.ref,
    required this.myUid,
    required this.groupId,
    required this.groupName,
    required this.starterUid,
  });

  String get callId => ref.id;
  bool muted = false;
  bool speaker = true;
  int seconds = 0;
  bool ended = false;
  String endReason = '';
  String? notice;

  /// Recording alerts: people (other than me) whose phone may be recording, and me.
  final Set<String> recordingUids = {};
  bool iRecording = false;
  Timer? _recDebounce;

  /// Everyone currently in the call except me, uid -> connected?
  final Map<String, bool> participants = {};
  final Map<String, String> names = {};

  MediaStream? _local;
  final Map<String, _Peer> _peers = {};
  StreamSubscription? _docSub;
  StreamSubscription? _sigSub;
  Timer? _ticker;
  bool _closed = false;
  bool _wasConnected = false;
  List<String> _joined = [];

  void _onLocalRecording(bool recording) {
    _recDebounce?.cancel();
    _recDebounce = Timer(Duration(seconds: recording ? 2 : 0), () {
      if (_closed || iRecording == recording) return;
      iRecording = recording;
      notifyListeners();
      ref.update({'rec.$myUid': recording}).catchError((_) {});
    });
  }

  Future<void> _begin({Map<String, dynamic>? create}) async {
    await CallQualityService.load();
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    if (create != null) {
      await ref.set(create);
      _joined = [myUid];
    } else {
      // Add myself only if there is still room.
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        if (data == null || data['status'] != 'active') throw StateError('This call has ended.');
        final joined = List<String>.from(data['joined'] ?? const []);
        if (!joined.contains(myUid)) {
          if (joined.length >= GroupCallService.maxParticipants) {
            throw StateError('This call is full (${GroupCallService.maxParticipants} people).');
          }
          tx.update(ref, {'joined': FieldValue.arrayUnion([myUid])});
        }
      });
    }
    IncomingCallNotifier.startOngoing('Group call · $groupName');
    if (CallQualityService.recordingAlerts) CallRecordingWatcher.start(_onLocalRecording);
    _sigSub = ref.collection('signals').where('to', isEqualTo: myUid).snapshots().listen(_onSignals, onError: (_) {});
    _docSub = ref.snapshots().listen(_onDoc, onError: (_) {});
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      seconds++;
      notifyListeners();
    });
    Helper.setSpeakerphoneOn(speaker);
  }

  Future<void> _onDoc(DocumentSnapshot<Map<String, dynamic>> snap) async {
    if (_closed) return;
    final data = snap.data();
    if (data == null || data['status'] == 'ended') {
      await _finish('Call ended');
      return;
    }
    _joined = List<String>.from(data['joined'] ?? const []);
    final rec = data['rec'];
    recordingUids
      ..clear()
      ..addAll(rec is Map ? rec.entries.where((e) => e.value == true && e.key != myUid && _joined.contains(e.key)).map((e) => e.key as String) : const <String>[]);
    final others = _joined.where((u) => u != myUid).toSet();
    // Someone left.
    for (final gone in _peers.keys.where((u) => !others.contains(u)).toList()) {
      await _dropPeer(gone);
    }
    participants.removeWhere((u, _) => !others.contains(u));
    for (final u in others) {
      participants.putIfAbsent(u, () => false);
      if (!names.containsKey(u)) {
        GroupCallService.instance.nameOf(u).then((n) {
          names[u] = n;
          if (!_closed) notifyListeners();
        });
      }
      // Fixed rule: the larger uid makes the offer.
      if (!_peers.containsKey(u) && myUid.compareTo(u) > 0) {
        await _offerTo(u);
      }
    }
    notifyListeners();
  }

  Future<_Peer> _newPeer(String uid) async {
    final peer = _Peer();
    _peers[uid] = peer;
    final pc = await createPeerConnection(CallService.rtcConfig);
    peer.pc = pc;
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      _signal(uid, {'kind': 'cand', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    };
    pc.onConnectionState = (RTCPeerConnectionState s) {
      final ok = s == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      if (ok) _wasConnected = true;
      if (peer.connected != ok) {
        peer.connected = ok;
        participants[uid] = ok;
        if (!_closed) notifyListeners();
      }
    };
    return peer;
  }

  Future<void> _offerTo(String uid) async {
    final peer = await _newPeer(uid);
    final rawOffer = await peer.pc!.createOffer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
    final offer = RTCSessionDescription(CallQualityService.tune(rawOffer.sdp), rawOffer.type);
    await peer.pc!.setLocalDescription(offer);
    await _signal(uid, {'kind': 'offer', 'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> _signal(String to, Map<String, dynamic> body) async {
    try {
      await ref.collection('signals').add({
        ...body,
        'from': myUid,
        'to': to,
        'expireAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 2))),
      });
    } catch (_) {}
  }

  Future<void> _onSignals(QuerySnapshot<Map<String, dynamic>> snap) async {
    final docs = snap.docChanges.where((c) => c.type == DocumentChangeType.added).map((c) => c.doc).toList();
    for (final doc in docs) {
      if (_closed) return;
      final d = doc.data();
      if (d == null) continue;
      final from = d['from'] as String;
      try {
        switch (d['kind']) {
          case 'offer':
            // A fresh offer replaces any half-finished attempt.
            if (_peers.containsKey(from)) await _dropPeer(from);
            final peer = await _newPeer(from);
            await peer.pc!.setRemoteDescription(RTCSessionDescription(CallQualityService.tune(d['sdp'] as String?), d['type'] as String?));
            peer.remoteSet = true;
            for (final c in peer.pending) {
              await peer.pc!.addCandidate(c);
            }
            peer.pending.clear();
            final rawAnswer = await peer.pc!.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
            final answer = RTCSessionDescription(CallQualityService.tune(rawAnswer.sdp), rawAnswer.type);
            await peer.pc!.setLocalDescription(answer);
            await _signal(from, {'kind': 'answer', 'sdp': answer.sdp, 'type': answer.type});
            participants.putIfAbsent(from, () => false);
            break;
          case 'answer':
            final peer = _peers[from];
            if (peer?.pc == null) break;
            await peer!.pc!.setRemoteDescription(RTCSessionDescription(CallQualityService.tune(d['sdp'] as String?), d['type'] as String?));
            peer.remoteSet = true;
            for (final c in peer.pending) {
              await peer.pc!.addCandidate(c);
            }
            peer.pending.clear();
            break;
          case 'cand':
            final cand = RTCIceCandidate(d['candidate'] as String?, d['sdpMid'] as String?, d['sdpMLineIndex'] as int?);
            final peer = _peers[from];
            if (peer == null) break;
            if (peer.remoteSet) {
              await peer.pc?.addCandidate(cand);
            } else {
              peer.pending.add(cand);
            }
            break;
        }
      } catch (_) {
      } finally {
        doc.reference.delete().catchError((_) {});
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _dropPeer(String uid) async {
    final peer = _peers.remove(uid);
    try {
      await peer?.pc?.close();
    } catch (_) {}
  }

  void setMuted(bool value) {
    muted = value;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !value;
    }
    notifyListeners();
  }

  void setSpeaker(bool value) {
    speaker = value;
    Helper.setSpeakerphoneOn(value);
    notifyListeners();
  }

  Future<void> leave() => _finish('You left the call', leaveDoc: true);

  Future<void> _finish(String reason, {bool leaveDoc = false}) async {
    if (_closed) return;
    _closed = true;
    endReason = reason;
    _ticker?.cancel();
    _recDebounce?.cancel();
    CallRecordingWatcher.stop();
    IncomingCallNotifier.stopOngoing();
    IncomingCallNotifier.showOverLockScreen(false);
    await _docSub?.cancel();
    await _sigSub?.cancel();
    if (leaveDoc) {
      try {
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(ref);
          final data = snap.data();
          if (data == null) return;
          final joined = List<String>.from(data['joined'] ?? const [])..remove(myUid);
          tx.update(ref, {'joined': joined, if (joined.isEmpty) 'status': 'ended'});
        });
      } catch (_) {}
    }
    for (final u in _peers.keys.toList()) {
      await _dropPeer(u);
    }
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      try {
        await t.stop();
      } catch (_) {}
    }
    await _local?.dispose();
    _local = null;
    ended = true;
    notifyListeners();
    _onClosed?.call();
    if (_wasConnected) {
      unawaited(CallLogService.instance.logGroup(
        callId: callId,
        groupId: groupId,
        starterUid: starterUid,
        text: 'Group voice call · ${CallLogService.mmss(seconds)}',
      ));
    }
  }
}
