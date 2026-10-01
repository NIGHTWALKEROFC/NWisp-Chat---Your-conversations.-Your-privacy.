import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'mlkem768.dart';
import 'signal_session_service.dart';

/// Feature: Telegram-style SECRET CHATS.
///
///  * Both people must have NWisp open at the same time. One asks, the other
///    taps Accept — there is no "message them for later".
///  * Nothing is stored on either phone: no database row, no chat-list entry,
///    no notification text, no backup. Messages live in memory only and are
///    wiped when someone leaves.
///  * Keys are brand new for every secret chat and exist only in memory
///    (X25519 + ML-KEM-768 together, so it is also quantum-resistant). The
///    handshake is signed with each person's Signal identity key, so the
///    server can't slip a man-in-the-middle in. Every message then uses its
///    own one-time key from a hash ratchet (old keys are erased as you go).
///  * The server (Firestore) only ever sees encrypted blobs, and the reader
///    deletes each blob as soon as it has opened it.
class SecretChatService {
  SecretChatService._();
  static final instance = SecretChatService._();

  final _db = FirebaseFirestore.instance;
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  final ValueNotifier<SecretInvite?> incomingInvite = ValueNotifier<SecretInvite?>(null);
  StreamSubscription? _inviteSub;
  SecretChatSession? _open;

  /// See CallService.handledCallId.
  String? handledInviteId;

  void startListening() {
    final uid = _myUid;
    if (uid == null) return;
    _inviteSub?.cancel();
    _inviteSub = _db
        .collection('secretChats')
        .where('invitee', isEqualTo: uid)
        .where('status', isEqualTo: 'requested')
        .snapshots()
        .listen((snap) {
      final now = DateTime.now();
      for (final d in snap.docs) {
        final data = d.data();
        final created = (data['createdAt'] as Timestamp?)?.toDate();
        if (created != null && now.difference(created) > const Duration(seconds: 75)) continue;
        if (_open != null) {
          d.reference.update({'status': 'declined'}).catchError((_) {});
          continue;
        }
        if (incomingInvite.value?.chatId == d.id) return;
        incomingInvite.value = SecretInvite(
          chatId: d.id,
          initiatorUid: data['initiator'] as String,
          initiatorName: (data['initiatorName'] as String?) ?? 'Someone',
        );
        return;
      }
      if (snap.docs.isEmpty) incomingInvite.value = null;
    }, onError: (_) {});
  }

  void stopListening() {
    _inviteSub?.cancel();
    _inviteSub = null;
    incomingInvite.value = null;
  }

  Future<SecretChatSession> startAsInitiator({required String peerUid, required String peerName, required String myName}) async {
    final uid = _myUid;
    if (uid == null) throw StateError('Not signed in.');
    if (_open != null) throw StateError('A secret chat is already open.');
    if (await SignalSessionService.instance.hasUnverifiedIdentityChange(peerUid)) {
      throw StateError("$peerName's security code changed. Verify it in the normal chat first.");
    }
    final ref = _db.collection('secretChats').doc();
    final s = SecretChatSession._(ref: ref, myUid: uid, peerUid: peerUid, peerName: peerName, isInitiator: true);
    _open = s;
    s._onClosed = () {
      if (identical(_open, s)) _open = null;
    };
    await s._initiate(myName: myName);
    return s;
  }

  Future<SecretChatSession> acceptInvite(SecretInvite invite) async {
    final uid = _myUid;
    if (uid == null) throw StateError('Not signed in.');
    if (_open != null) throw StateError('A secret chat is already open.');
    handledInviteId = invite.chatId;
    incomingInvite.value = null;
    final ref = _db.collection('secretChats').doc(invite.chatId);
    final s = SecretChatSession._(ref: ref, myUid: uid, peerUid: invite.initiatorUid, peerName: invite.initiatorName, isInitiator: false);
    _open = s;
    s._onClosed = () {
      if (identical(_open, s)) _open = null;
    };
    await s._accept();
    return s;
  }

  Future<void> declineInvite(SecretInvite invite) async {
    handledInviteId = invite.chatId;
    incomingInvite.value = null;
    try {
      await _db.collection('secretChats').doc(invite.chatId).update({'status': 'declined'});
    } catch (_) {}
  }
}

class SecretInvite {
  final String chatId;
  final String initiatorUid;
  final String initiatorName;
  SecretInvite({required this.chatId, required this.initiatorUid, required this.initiatorName});
}

enum SecretPhase { waiting, active, peerLeft, declined, timedOut, failed, closed }

class SecretMessage {
  final String id;
  final bool mine;
  final String text;
  final int ms;
  DateTime? expiresAt;
  SecretMessage({required this.id, required this.mine, required this.text, required this.ms, this.expiresAt});
}

/// One live secret chat. Everything in here is in memory only.
class SecretChatSession extends ChangeNotifier {
  final DocumentReference<Map<String, dynamic>> ref;
  final String myUid;
  final String peerUid;
  final String peerName;
  final bool isInitiator;
  VoidCallback? _onClosed;

  SecretChatSession._({
    required this.ref,
    required this.myUid,
    required this.peerUid,
    required this.peerName,
    required this.isInitiator,
  });

  SecretPhase phase = SecretPhase.waiting;
  String failMessage = '';
  final List<SecretMessage> messages = [];
  int timerSeconds = 0;
  String fingerprint = '';
  bool peerOnline = true;

  static const _label = 'NWisp-SC-v1';
  final _x25519 = X25519();
  final _aes = AesGcm.with256bits();
  final _hmac = Hmac.sha256();
  final _rand = Random.secure();

  SimpleKeyPair? _myX;
  Uint8List? _myKemDk;
  List<int>? _sendChain;
  List<int>? _recvChain;
  int _sendSeq = 0;
  int _recvNext = 0;
  final Map<int, List<int>> _skipped = {};
  final Set<String> _seenDocs = {};

  StreamSubscription? _docSub;
  StreamSubscription? _msgSub;
  Timer? _heartbeat;
  Timer? _watchdog;
  Timer? _reaper;
  Timer? _requestTimeout;
  DateTime _lastPeerBeat = DateTime.now();
  dynamic _lastPeerBeatValue;
  bool _closed = false;

  CollectionReference<Map<String, dynamic>> get _msgs => ref.collection('msgs');

  Uint8List _rand32() => Uint8List.fromList(List<int>.generate(32, (_) => _rand.nextInt(256)));

  Future<List<int>> _mac(List<int> key, int tag) async =>
      (await _hmac.calculateMac([tag], secretKey: SecretKey(key))).bytes;

  Future<List<int>> _hash(List<int> data) async => (await Sha256().hash(data)).bytes;

  // ------------------------------------------------------------ handshake
  Future<void> _initiate({required String myName}) async {
    _myX = await _x25519.newKeyPair();
    final xPub = (await _myX!.extractPublicKey()).bytes;
    final (ek, dk) = MlKem768.keyGen(List<int>.generate(64, (_) => _rand.nextInt(256)));
    _myKemDk = dk;
    final payload = Uint8List.fromList(utf8.encode('$_label|${ref.id}|$myUid|$peerUid|') + xPub + ek);
    final sig = await SignalSessionService.instance.signWithIdentity(payload);
    await ref.set({
      'participants': [myUid, peerUid],
      'initiator': myUid,
      'invitee': peerUid,
      'initiatorName': myName,
      'status': 'requested',
      'x': base64Encode(xPub),
      'kem': base64Encode(ek),
      'sig': base64Encode(sig),
      'timer': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'expireAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 2))),
    });
    _docSub = ref.snapshots().listen(_onDoc, onError: (_) => _fail('Connection problem.'));
    // Feature: secret-chat invite push — lets the other phone show "Secret
    // chat request" even with NWisp closed. The text deliberately leaves the
    // name out so it can't be read on a lock screen.
    _pushInvite();
    _requestTimeout = Timer(const Duration(seconds: 60), () {
      if (phase == SecretPhase.waiting) {
        ref.update({'status': 'ended'}).catchError((_) {});
        _setPhase(SecretPhase.timedOut);
        _teardown(deleteDoc: true);
      }
    });
  }

  Future<void> _pushInvite() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();
      final base = const String.fromEnvironment('SUPABASE_URL');
      await http
          .post(
            Uri.parse('$base/functions/v1/send-call-push'),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'kind': 'secret_invite', 'chatId': ref.id, 'inviteeUid': peerUid}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  Future<void> _accept() async {
    final snap = await ref.get();
    final d = snap.data();
    if (d == null || d['status'] != 'requested') {
      _setPhase(SecretPhase.failed, 'This request is no longer available.');
      return;
    }
    final aXPub = base64Decode(d['x'] as String);
    final aEk = base64Decode(d['kem'] as String);
    final aSig = base64Decode(d['sig'] as String);
    final aPayload = Uint8List.fromList(utf8.encode('$_label|${ref.id}|$peerUid|$myUid|') + aXPub + aEk);
    if (!await SignalSessionService.instance.verifyPeerSignature(peerUid, aPayload, aSig)) {
      _setPhase(SecretPhase.failed, "The handshake signature didn't check out — this could be an attack. Nothing was started.");
      await ref.update({'status': 'declined'}).catchError((_) {});
      return;
    }
    _myX = await _x25519.newKeyPair();
    final bXPub = (await _myX!.extractPublicKey()).bytes;
    final shared = await _x25519.sharedSecretKey(
      keyPair: _myX!,
      remotePublicKey: SimplePublicKey(aXPub, type: KeyPairType.x25519),
    );
    final ssX = await shared.extractBytes();
    final (ssPq, kemCt) = MlKem768.encapsulate(aEk, _rand32());
    await _deriveKeys(ssX, ssPq);
    final respPayload = Uint8List.fromList(
      utf8.encode('$_label-resp|${ref.id}|') + await _hash(aPayload) + bXPub + kemCt,
    );
    final sig = await SignalSessionService.instance.signWithIdentity(respPayload);
    await ref.update({
      'rx': base64Encode(bXPub),
      'rkem': base64Encode(kemCt),
      'rsig': base64Encode(sig),
      'status': 'active',
      'hbStart': FieldValue.serverTimestamp(),
    });
    timerSeconds = (d['timer'] as int?) ?? 0;
    _goActive();
  }

  Future<void> _finishInitiator(Map<String, dynamic> d) async {
    if (_sendChain != null) return;
    try {
      final bXPub = base64Decode(d['rx'] as String);
      final kemCt = base64Decode(d['rkem'] as String);
      final bSig = base64Decode(d['rsig'] as String);
      final aX = base64Decode(d['x'] as String);
      final aEk = base64Decode(d['kem'] as String);
      final aPayload = Uint8List.fromList(utf8.encode('$_label|${ref.id}|$myUid|$peerUid|') + aX + aEk);
      final respPayload = Uint8List.fromList(
        utf8.encode('$_label-resp|${ref.id}|') + await _hash(aPayload) + bXPub + kemCt,
      );
      if (!await SignalSessionService.instance.verifyPeerSignature(peerUid, respPayload, bSig)) {
        _fail("The other side's signature didn't check out — this could be an attack. The chat was closed.");
        return;
      }
      final shared = await _x25519.sharedSecretKey(
        keyPair: _myX!,
        remotePublicKey: SimplePublicKey(bXPub, type: KeyPairType.x25519),
      );
      final ssX = await shared.extractBytes();
      final ssPq = MlKem768.decapsulate(_myKemDk!, kemCt);
      await _deriveKeys(ssX, ssPq);
      _requestTimeout?.cancel();
      _goActive();
    } catch (_) {
      _fail("Couldn't set up the secure channel.");
    }
  }

  Future<void> _deriveKeys(List<int> ssX, List<int> ssPq) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 96);
    final out = await (await hkdf.deriveKey(
      secretKey: SecretKey([...ssX, ...ssPq]),
      nonce: utf8.encode('$_label-root'),
      info: utf8.encode(ref.id),
    ))
        .extractBytes();
    final aToB = out.sublist(0, 32);
    final bToA = out.sublist(32, 64);
    final fp = out.sublist(64, 96);
    _sendChain = isInitiator ? aToB : bToA;
    _recvChain = isInitiator ? bToA : aToB;
    final hex = fp.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    fingerprint = [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ');
    // Wipe the only local copy of the ephemeral private material.
    _myKemDk = null;
    _myX = null;
  }

  void _goActive() {
    _lastPeerBeat = DateTime.now();
    // The person who accepted hasn't been watching the session record yet.
    _docSub ??= ref.snapshots().listen(_onDoc, onError: (_) => _fail('Connection problem.'));
    _setPhase(SecretPhase.active);
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      ref.update({'hb.$myUid': FieldValue.serverTimestamp()}).catchError((_) {});
    });
    ref.update({'hb.$myUid': FieldValue.serverTimestamp()}).catchError((_) {});
    _watchdog = Timer.periodic(const Duration(seconds: 4), (_) {
      if (phase != SecretPhase.active) return;
      final offline = DateTime.now().difference(_lastPeerBeat) > const Duration(seconds: 22);
      if (offline) _peerGone();
    });
    _reaper = Timer.periodic(const Duration(seconds: 1), (_) => _reap());
    _msgSub = _msgs.where('to', isEqualTo: myUid).snapshots().listen(_onMsgs, onError: (_) {});
  }

  // ------------------------------------------------------------ doc events
  void _onDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data();
    if (_closed) return;
    if (d == null) {
      if (phase == SecretPhase.active) _peerGone();
      return;
    }
    final status = d['status'] as String?;
    if (status == 'declined' && phase == SecretPhase.waiting) {
      _setPhase(SecretPhase.declined);
      _teardown(deleteDoc: true);
      return;
    }
    if (status == 'active' && isInitiator && _sendChain == null) {
      _finishInitiator(d);
    }
    if (status == 'ended' && phase == SecretPhase.active) {
      _peerGone();
      return;
    }
    final t = (d['timer'] as int?) ?? 0;
    if (t != timerSeconds) {
      timerSeconds = t;
      notifyListeners();
    }
    final hb = d['hb'];
    if (hb is Map) {
      final v = hb[peerUid];
      if (v != null && v != _lastPeerBeatValue) {
        _lastPeerBeatValue = v;
        _lastPeerBeat = DateTime.now();
        if (!peerOnline) {
          peerOnline = true;
          notifyListeners();
        }
      }
    }
  }

  void _peerGone() {
    if (_closed || phase == SecretPhase.peerLeft) return;
    peerOnline = false;
    _setPhase(SecretPhase.peerLeft);
    // Stop everything; the messages stay on screen (read-only) until this
    // person also leaves, then they are wiped.
    _heartbeat?.cancel();
    _watchdog?.cancel();
    _msgSub?.cancel();
    _sendChain = null;
    _recvChain = null;
    _skipped.clear();
  }

  // -------------------------------------------------------------- messages
  Future<void> setTimer(int seconds) async {
    timerSeconds = seconds;
    notifyListeners();
    try {
      await ref.update({'timer': seconds});
    } catch (_) {}
  }

  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty || phase != SecretPhase.active || _sendChain == null) return;
    final seq = _sendSeq++;
    final key = await _mac(_sendChain!, 1);
    _sendChain = await _mac(_sendChain!, 2);
    final ms = DateTime.now().millisecondsSinceEpoch;
    final nonce = List<int>.generate(12, (_) => _rand.nextInt(256));
    final aad = utf8.encode('${ref.id}|$myUid|$seq');
    final box = await _aes.encrypt(utf8.encode(jsonEncode({'t': t, 'ms': ms})), secretKey: SecretKey(key), nonce: nonce, aad: aad);
    final msg = SecretMessage(id: 'me_$seq', mine: true, text: t, ms: ms);
    if (timerSeconds > 0) msg.expiresAt = DateTime.now().add(Duration(seconds: timerSeconds));
    messages.add(msg);
    notifyListeners();
    await _msgs.add({
      'from': myUid,
      'to': peerUid,
      'seq': seq,
      'ct': base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]),
      'expireAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 1))),
    });
  }

  Future<void> _onMsgs(QuerySnapshot<Map<String, dynamic>> snap) async {
    final docs = snap.docChanges.where((c) => c.type == DocumentChangeType.added).map((c) => c.doc).toList()
      ..sort((a, b) => ((a.data()?['seq'] as int?) ?? 0).compareTo((b.data()?['seq'] as int?) ?? 0));
    for (final doc in docs) {
      if (_closed || _recvChain == null) return;
      if (!_seenDocs.add(doc.id)) continue;
      final d = doc.data();
      if (d == null) continue;
      try {
        final seq = d['seq'] as int;
        List<int>? key;
        if (seq < _recvNext) {
          key = _skipped.remove(seq);
        } else {
          if (seq - _recvNext > 200) throw Exception('gap too large');
          while (_recvNext < seq) {
            _skipped[_recvNext] = await _mac(_recvChain!, 1);
            _recvChain = await _mac(_recvChain!, 2);
            _recvNext++;
          }
          key = await _mac(_recvChain!, 1);
          _recvChain = await _mac(_recvChain!, 2);
          _recvNext++;
        }
        if (key == null) continue;
        final raw = base64Decode(d['ct'] as String);
        final nonce = raw.sublist(0, 12);
        final body = raw.sublist(12);
        final box = SecretBox(body.sublist(0, body.length - 16), nonce: nonce, mac: Mac(body.sublist(body.length - 16)));
        final clear = await _aes.decrypt(box, secretKey: SecretKey(key), aad: utf8.encode('${ref.id}|$peerUid|$seq'));
        final j = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        final m = SecretMessage(id: doc.id, mine: false, text: j['t'] as String, ms: j['ms'] as int);
        if (timerSeconds > 0) m.expiresAt = DateTime.now().add(Duration(seconds: timerSeconds));
        messages.add(m);
        notifyListeners();
      } catch (_) {
        // A message that fails its integrity check is dropped, never shown.
      } finally {
        // Delete the server copy as soon as it has been handled.
        doc.reference.delete().catchError((_) {});
      }
    }
  }

  void _reap() {
    final now = DateTime.now();
    final before = messages.length;
    messages.removeWhere((m) => m.expiresAt != null && m.expiresAt!.isBefore(now));
    if (messages.length != before) notifyListeners();
  }

  // -------------------------------------------------------------- lifecycle
  void _setPhase(SecretPhase p, [String message = '']) {
    phase = p;
    failMessage = message;
    notifyListeners();
  }

  void _fail(String message) {
    _setPhase(SecretPhase.failed, message);
    _teardown(deleteDoc: true);
  }

  /// Leave the chat: everything is erased on this phone and the other side
  /// is told this person went offline.
  Future<void> leave() async {
    if (_closed) return;
    try {
      await ref.update({'status': 'ended'});
    } catch (_) {}
    await _teardown(deleteDoc: true);
    messages.clear();
    _setPhase(SecretPhase.closed);
  }

  Future<void> _teardown({required bool deleteDoc}) async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    _watchdog?.cancel();
    _reaper?.cancel();
    _requestTimeout?.cancel();
    await _msgSub?.cancel();
    await _docSub?.cancel();
    _sendChain = null;
    _recvChain = null;
    _skipped.clear();
    _myKemDk = null;
    _myX = null;
    if (deleteDoc) {
      try {
        final mine = await _msgs.where('from', isEqualTo: myUid).get();
        for (final d in mine.docs) {
          await d.reference.delete();
        }
        // The initiator removes the whole session record a little later, so
        // the other side still gets to see the "ended" status first.
        if (isInitiator) {
          Timer(const Duration(seconds: 20), () => ref.delete().catchError((_) {}));
        }
      } catch (_) {}
    }
    _onClosed?.call();
  }

  /// Called when the screen is disposed for any reason.
  Future<void> dispose_() async {
    if (!_closed) await leave();
    messages.clear();
  }
}
