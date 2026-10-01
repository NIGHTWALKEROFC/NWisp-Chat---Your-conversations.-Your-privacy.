import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'call_log_service.dart';
import 'incoming_call_notifier.dart';

/// Feature: voice calls (audio only — no video, so very little data).
///
/// How it works, in plain words:
///  * Audio travels phone-to-phone with WebRTC (Opus codec, roughly
///    20-40 kbit/s, so about 0.2-0.3 MB per minute). WebRTC always encrypts
///    the audio (DTLS-SRTP).
///  * The two phones find each other by swapping small "signalling" notes
///    through Firestore (`calls/{callId}`). No audio ever goes through
///    Firestore or Supabase, so nothing here counts against a Supabase
///    limit and Firestore only sees a handful of tiny writes per call.
///  * If a direct path isn't possible (strict mobile networks), a TURN
///    relay is needed — optional, see the setup notes (TURN_URL etc).
class CallService {
  CallService._();
  static final instance = CallService._();

  final _db = FirebaseFirestore.instance;
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  static const _turnUrl = String.fromEnvironment('TURN_URL');
  static const _turnUser = String.fromEnvironment('TURN_USER');
  static const _turnPass = String.fromEnvironment('TURN_PASS');

  static Map<String, dynamic> get rtcConfig => {
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302']},
          if (_turnUrl.isNotEmpty) {'urls': _turnUrl.split(','), 'username': _turnUser, 'credential': _turnPass},
        ],
      };

  // ------------------------------------------------------------ incoming
  /// The call currently ringing on this phone (or null). HomeShell listens
  /// and shows the incoming-call screen.
  final ValueNotifier<IncomingCall?> incoming = ValueNotifier<IncomingCall?>(null);
  StreamSubscription? _incomingSub;

  /// Set the moment the person taps Answer or Decline, so the home screen
  /// knows a vanished ringing screen was their doing and not a hang-up.
  String? handledCallId;

  void startListening() {
    final uid = _myUid;
    if (uid == null) return;
    _incomingSub?.cancel();
    _incomingSub = _db
        .collection('calls')
        .where('calleeUid', isEqualTo: uid)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snap) {
      final now = DateTime.now();
      for (final d in snap.docs) {
        final data = d.data();
        final created = (data['createdAt'] as Timestamp?)?.toDate();
        // Ignore stale ringing docs left behind by a crash.
        if (created != null && now.difference(created) > const Duration(seconds: 60)) continue;
        if (_active != null) {
          // Already in a call — tell the caller we're busy.
          d.reference.update({'status': 'busy'}).catchError((_) {});
          continue;
        }
        if (incoming.value?.callId == d.id) return;
        incoming.value = IncomingCall(
          callId: d.id,
          callerUid: data['callerUid'] as String,
          callerName: (data['callerName'] as String?) ?? 'Unknown',
          conversationId: (data['conversationId'] as String?) ?? '',
        );
        return;
      }
      if (snap.docs.isEmpty) incoming.value = null;
    }, onError: (_) {});
  }

  void stopListening() {
    _incomingSub?.cancel();
    _incomingSub = null;
    incoming.value = null;
  }

  // -------------------------------------------------------------- session
  VoiceCallSession? _active;
  VoiceCallSession? get active => _active;

  /// Starts an outgoing call to [peerUid]. Needs an existing chat with them
  /// (the Firestore security rules require it).
  Future<VoiceCallSession> startCall({
    required String conversationId,
    required String peerUid,
    required String peerName,
    required String myName,
  }) async {
    final uid = _myUid;
    if (uid == null) throw StateError('Not signed in.');
    if (_active != null) throw StateError('You are already in a call.');
    final ref = _db.collection('calls').doc();
    final session = VoiceCallSession._(ref: ref, myUid: uid, peerUid: peerUid, peerName: peerName, isCaller: true, config: rtcConfig, conversationId: conversationId);
    _active = session;
    session._onClosed = () {
      if (identical(_active, session)) _active = null;
    };
    await session._startAsCaller(conversationId: conversationId, myName: myName);
    unawaited(_pushRing(ref.id, peerUid));
    return session;
  }

  Future<VoiceCallSession> acceptCall(IncomingCall call) async {
    handledCallId = call.callId;
    IncomingCallNotifier.cancelRing();
    final uid = _myUid;
    if (uid == null) throw StateError('Not signed in.');
    final ref = _db.collection('calls').doc(call.callId);
    final session = VoiceCallSession._(ref: ref, myUid: uid, peerUid: call.callerUid, peerName: call.callerName, isCaller: false, config: rtcConfig, conversationId: call.conversationId);
    _active = session;
    session._onClosed = () {
      if (identical(_active, session)) _active = null;
    };
    incoming.value = null;
    await session._startAsCallee();
    return session;
  }

  Future<void> declineCall(IncomingCall call) async {
    handledCallId = call.callId;
    IncomingCallNotifier.cancelRing();
    IncomingCallNotifier.showOverLockScreen(false);
    incoming.value = null;
    try {
      await _db.collection('calls').doc(call.callId).update({'status': 'declined'});
    } catch (_) {}
    await CallLogService.instance.logDirect(
      callId: call.callId,
      conversationId: call.conversationId,
      peerUid: call.callerUid,
      outgoing: false,
      text: 'Declined call',
    );
  }

  /// Best-effort push so the other phone shows "Incoming voice call" even
  /// with the app closed. Uses the send-call-push Edge Function.
  Future<void> _pushRing(String callId, String calleeUid) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();
      final base = const String.fromEnvironment('SUPABASE_URL');
      await http
          .post(
            Uri.parse('$base/functions/v1/send-call-push'),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'kind': 'call', 'callId': callId, 'calleeUid': calleeUid}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}

class IncomingCall {
  final String callId;
  final String callerUid;
  final String callerName;
  final String conversationId;
  IncomingCall({required this.callId, required this.callerUid, required this.callerName, this.conversationId = ''});
}

enum CallPhase { calling, ringing, connecting, connected, ended }

/// One live call. Screens listen to [phase], [muted], [speaker], [seconds].
class VoiceCallSession {
  final DocumentReference<Map<String, dynamic>> ref;
  final String myUid;
  final String peerUid;
  final String peerName;
  final bool isCaller;
  final Map<String, dynamic> config;
  final String conversationId;
  VoidCallback? _onClosed;
  bool _everConnected = false;
  String _finalStatus = 'ended';
  String _outcome = 'Call ended';

  VoiceCallSession._({
    required this.ref,
    required this.myUid,
    required this.peerUid,
    required this.peerName,
    required this.isCaller,
    required this.config,
    required this.conversationId,
  });

  final phase = ValueNotifier<CallPhase>(CallPhase.calling);
  final muted = ValueNotifier<bool>(false);
  final speaker = ValueNotifier<bool>(false);
  final seconds = ValueNotifier<int>(0);
  String endReason = '';

  RTCPeerConnection? _pc;
  MediaStream? _local;
  StreamSubscription? _docSub;
  StreamSubscription? _candSub;
  Timer? _ringTimeout;
  Timer? _ticker;
  bool _closed = false;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingRemote = [];

  String get _mineCol => isCaller ? 'callerCandidates' : 'calleeCandidates';
  String get _theirsCol => isCaller ? 'calleeCandidates' : 'callerCandidates';

  Future<void> _setupPeer() async {
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    final pc = await createPeerConnection(config);
    _pc = pc;
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      ref.collection(_mineCol).add({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}).catchError((_) => ref);
    };
    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _ringTimeout?.cancel();
        if (phase.value != CallPhase.connected) {
          _everConnected = true;
          IncomingCallNotifier.startOngoing('On a call with $peerName');
          phase.value = CallPhase.connected;
          _ticker = Timer.periodic(const Duration(seconds: 1), (_) => seconds.value++);
          Helper.setSpeakerphoneOn(speaker.value);
        }
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finish('Connection lost', updateDoc: true);
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Brief drops are normal on mobile networks; give it a moment to recover.
        Timer(const Duration(seconds: 12), () {
          if (!_closed && _pc?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            _finish('Connection lost', updateDoc: true);
          }
        });
      }
    };
  }

  void _listenCandidates() {
    _candSub = ref.collection(_theirsCol).snapshots().listen((snap) async {
      for (final ch in snap.docChanges) {
        if (ch.type != DocumentChangeType.added) continue;
        final d = ch.doc.data();
        if (d == null) continue;
        final cand = RTCIceCandidate(d['candidate'] as String?, d['sdpMid'] as String?, d['sdpMLineIndex'] as int?);
        if (_remoteSet) {
          await _pc?.addCandidate(cand);
        } else {
          _pendingRemote.add(cand);
        }
      }
    });
  }

  Future<void> _flushPending() async {
    _remoteSet = true;
    for (final c in _pendingRemote) {
      await _pc?.addCandidate(c);
    }
    _pendingRemote.clear();
  }

  Future<void> _startAsCaller({required String conversationId, required String myName}) async {
    await _setupPeer();
    final offer = await _pc!.createOffer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
    await _pc!.setLocalDescription(offer);
    await ref.set({
      'callerUid': myUid,
      'calleeUid': peerUid,
      'callerName': myName,
      'conversationId': conversationId,
      'status': 'ringing',
      'offer': {'sdp': offer.sdp, 'type': offer.type},
      'createdAt': FieldValue.serverTimestamp(),
      'expireAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 1))),
    });
    _listenCandidates();
    _docSub = ref.snapshots().listen((snap) async {
      final data = snap.data();
      if (data == null || _closed) return;
      final status = data['status'] as String?;
      final answer = data['answer'] as Map<String, dynamic>?;
      if (answer != null && !_remoteSet) {
        phase.value = CallPhase.connecting;
        await _pc!.setRemoteDescription(RTCSessionDescription(answer['sdp'] as String?, answer['type'] as String?));
        await _flushPending();
      } else if (status == 'ringing' && phase.value == CallPhase.calling) {
        phase.value = CallPhase.ringing;
      }
      if (status == 'declined') _finish('Call declined', updateDoc: false, outcome: 'Call declined');
      if (status == 'busy') _finish('Busy on another call', updateDoc: false, outcome: 'Busy');
      if (status == 'ended') _finish('Call ended', updateDoc: false);
    });
    _ringTimeout = Timer(const Duration(seconds: 45), () {
      if (phase.value == CallPhase.calling || phase.value == CallPhase.ringing) {
        ref.update({'status': 'missed'}).catchError((_) {});
        _finish('No answer', updateDoc: false, outcome: 'No answer', finalStatus: 'missed');
      }
    });
  }

  Future<void> _startAsCallee() async {
    phase.value = CallPhase.connecting;
    final snap = await ref.get();
    final data = snap.data();
    if (data == null || data['status'] != 'ringing') {
      _finish('Call is no longer available', updateDoc: false);
      return;
    }
    await _setupPeer();
    final offer = data['offer'] as Map<String, dynamic>;
    await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String?, offer['type'] as String?));
    _listenCandidates();
    await _flushPending();
    final answer = await _pc!.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
    await _pc!.setLocalDescription(answer);
    await ref.update({
      'answer': {'sdp': answer.sdp, 'type': answer.type},
      'status': 'active',
    });
    _docSub = ref.snapshots().listen((s) {
      final st = s.data()?['status'] as String?;
      if (st == 'ended' || st == 'missed') _finish('Call ended', updateDoc: false);
    });
    _ringTimeout = Timer(const Duration(seconds: 30), () {
      if (phase.value != CallPhase.connected) _finish('Could not connect', updateDoc: true);
    });
  }

  void setMuted(bool value) {
    muted.value = value;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !value;
    }
  }

  void setSpeaker(bool value) {
    speaker.value = value;
    Helper.setSpeakerphoneOn(value);
  }

  /// Hang up (or cancel while ringing).
  Future<void> hangUp() => _finish('Call ended', updateDoc: true);

  Future<void> _finish(String reason, {required bool updateDoc, String? outcome, String? finalStatus}) async {
    if (_closed) return;
    _closed = true;
    endReason = reason;
    if (finalStatus != null) _finalStatus = finalStatus;
    // Hanging up before anyone picked up counts as a missed call for them.
    if (updateDoc && isCaller && !_everConnected) _finalStatus = 'missed';
    if (outcome != null) _outcome = outcome;
    IncomingCallNotifier.cancelRing();
    IncomingCallNotifier.stopOngoing();
    IncomingCallNotifier.showOverLockScreen(false);
    _ringTimeout?.cancel();
    _ticker?.cancel();
    if (updateDoc) {
      try {
        await ref.update({'status': _finalStatus});
      } catch (_) {}
    }
    // The chat line for this call (see CallLogService).
    final String line;
    if (_everConnected) {
      line = 'Voice call · ${CallLogService.mmss(seconds.value)}';
    } else if (isCaller) {
      line = _finalStatus == 'missed' && _outcome == 'Call ended' ? 'Cancelled call' : _outcome;
    } else {
      line = 'Missed voice call';
    }
    unawaited(CallLogService.instance.logDirect(
      callId: ref.id,
      conversationId: conversationId,
      peerUid: peerUid,
      outgoing: isCaller,
      text: line,
    ));
    await _docSub?.cancel();
    await _candSub?.cancel();
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      try {
        await t.stop();
      } catch (_) {}
    }
    await _local?.dispose();
    await _pc?.close();
    _pc = null;
    _local = null;
    phase.value = CallPhase.ended;
    _onClosed?.call();
    // Only the caller cleans the signalling notes up (rules allow either) —
    // except for a missed call, whose record is kept so the other phone can
    // add "Missed voice call" to its chat next time it opens NWisp.
    if (isCaller && _finalStatus != 'missed') {
      Timer(const Duration(seconds: 5), () async {
        try {
          for (final col in ['callerCandidates', 'calleeCandidates']) {
            final s = await ref.collection(col).get();
            for (final d in s.docs) {
              await d.reference.delete();
            }
          }
          await ref.delete();
        } catch (_) {}
      });
    }
  }
}
