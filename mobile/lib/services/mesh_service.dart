import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'nearby_service.dart';
import 'signal_session_service.dart';

class MeshMessage {
  final String id;
  final String fromUid;
  final String fromName;
  final String text;
  final DateTime at;
  final bool mine;
  final int hops;
  /// true = signature checks out AND the sender's key matches the one this
  /// phone already knew for that person.
  final bool verified;
  MeshMessage({
    required this.id,
    required this.fromUid,
    required this.fromName,
    required this.text,
    required this.mine,
    required this.hops,
    required this.verified,
  }) : at = DateTime.now();
}

/// Someone reachable through the mesh (not necessarily directly linked).
class MeshNode {
  final String uid;
  String name;
  final Uint8List idKey;
  final Uint8List xPub;
  bool verified;
  int hops;
  DateTime lastSeen;
  MeshNode(this.uid, this.name, this.idKey, this.xPub, this.verified, this.hops) : lastSeen = DateTime.now();
}

/// Feature: multi-hop mesh relay for Nearby chat (the bitchat idea).
///
/// Phones that switch "Mesh relay" on link to each other automatically and
/// pass messages along, so two people who are out of each other's radio range
/// can still reach each other through phones in between.
///
///  * Public room — a local chat room for everyone on the mesh. Messages are
///    signed so they can't be altered, but ANYONE on the mesh can read them.
///  * Direct messages — end-to-end encrypted to the other person (X25519 +
///    AES-256-GCM). Phones in between only see an unreadable blob.
///  * Every message carries a random id and a hop limit; a phone passes each
///    id along once, so messages can't loop. Nothing is saved: it all lives
///    in memory and is gone when the app closes or Mesh is switched off.
///
/// Nothing here uses the internet or any server.
class MeshService extends ChangeNotifier {
  MeshService._();
  static final instance = MeshService._();

  static const _pubTtl = 5;
  static const _dmTtl = 6;
  static const _annTtl = 4;
  static const _maxRoom = 200;

  final _x25519 = X25519();
  final _aes = AesGcm.with256bits();
  final _rand = Random.secure();

  final List<MeshMessage> room = [];
  final Map<String, MeshNode> nodes = {};
  final Map<String, List<MeshMessage>> threads = {};
  final Map<String, int> unread = {};
  final Set<String> muted = {};
  int roomUnread = 0;

  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  final Map<String, int> _linkCount = {};
  DateTime _windowStart = DateTime.now();
  SimpleKeyPair? _kp;
  Uint8List? _myX;
  Timer? _annTimer;
  Timer? _pruneTimer;

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;
  String get _myName => NearbyService.instance.myName.isEmpty ? 'nwisp' : NearbyService.instance.myName;

  List<MeshNode> get nodeList {
    final l = nodes.values.where((n) => !muted.contains(n.uid)).toList()
      ..sort((a, b) => a.hops != b.hops ? a.hops.compareTo(b.hops) : a.name.compareTo(b.name));
    return l;
  }

  String _newId() => List<int>.generate(12, (_) => _rand.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool _markSeen(String id) {
    if (_seen.contains(id)) return false;
    _seen.add(id);
    if (_seen.length > 1000) _seen.remove(_seen.first);
    return true;
  }

  // ------------------------------------------------------------ lifecycle
  Future<void> _ensureKeys() async {
    if (_kp != null) return;
    _kp = await _x25519.newKeyPair();
    _myX = Uint8List.fromList((await _kp!.extractPublicKey()).bytes);
  }

  Future<void> onLinkUp(String endpointId) async {
    await _ensureKeys();
    _annTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _announce());
    _pruneTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _prune());
    await _announce(only: endpointId);
    notifyListeners();
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 3));
    final before = nodes.length;
    nodes.removeWhere((_, n) => n.lastSeen.isBefore(cutoff));
    if (NearbyService.instance.meshLinks.isEmpty && _annTimer != null) {
      _annTimer?.cancel();
      _annTimer = null;
    }
    if (nodes.length != before) notifyListeners();
  }

  void reset() {
    _annTimer?.cancel();
    _pruneTimer?.cancel();
    _annTimer = null;
    _pruneTimer = null;
    room.clear();
    nodes.clear();
    threads.clear();
    unread.clear();
    muted.clear();
    roomUnread = 0;
    _seen.clear();
    _kp = null;
    _myX = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ helpers
  Uint8List _bytes(String b64) => base64Decode(b64);

  Future<bool> _isPinnedMatch(String uid, Uint8List key) async {
    final pinned = await SignalSessionService.instance.pinnedPeerIdentityKey(uid);
    return pinned != null && listEquals(pinned, key);
  }

  Future<bool?> _pinnedState(String uid, Uint8List key) async {
    final pinned = await SignalSessionService.instance.pinnedPeerIdentityKey(uid);
    if (pinned == null) return null; // never met before
    return listEquals(pinned, key);
  }

  Uint8List _sigText(String kind, List<String> parts) => Uint8List.fromList(utf8.encode('NWisp-mesh-$kind-v1|${parts.join('|')}'));

  void _flood(Map<String, dynamic> m, {String? except}) {
    final ttl = (m['ttl'] as int?) ?? 0;
    if (ttl <= 0) return;
    final out = Map<String, dynamic>.from(m)
      ..['ttl'] = ttl - 1
      ..['h'] = ((m['h'] as int?) ?? 0) + 1;
    for (final link in NearbyService.instance.meshLinks) {
      if (link.endpointId == except) continue;
      NearbyService.instance.sendRaw(link.endpointId, out);
    }
  }

  void _sendOriginal(Map<String, dynamic> m) {
    for (final link in NearbyService.instance.meshLinks) {
      NearbyService.instance.sendRaw(link.endpointId, m);
    }
  }

  // ------------------------------------------------------------ announce
  Future<void> _announce({String? only}) async {
    final uid = _myUid;
    if (uid == null) return;
    await _ensureKeys();
    final key = await SignalSessionService.instance.myIdentityPublicKeyBytes();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final x = base64Encode(_myX!);
    final sig = await SignalSessionService.instance.signWithIdentity(_sigText('ann', [uid, x, '$ts']));
    final m = {
      't': 'ann', 'id': _newId(), 'ttl': _annTtl, 'h': 0,
      'n': _myName, 'u': uid, 'k': base64Encode(key), 'x': x, 'ts': ts, 'sig': base64Encode(sig),
    };
    _markSeen(m['id'] as String);
    if (only != null) {
      NearbyService.instance.sendRaw(only, m);
    } else {
      _sendOriginal(m);
    }
  }

  // ------------------------------------------------------------ receiving
  Future<void> onBytes(String fromEndpoint, Map<String, dynamic> m) async {
    // Basic flood protection: at most 80 messages per 10 s per link.
    final now = DateTime.now();
    if (now.difference(_windowStart) > const Duration(seconds: 10)) {
      _windowStart = now;
      _linkCount.clear();
    }
    final n = (_linkCount[fromEndpoint] ?? 0) + 1;
    _linkCount[fromEndpoint] = n;
    if (n > 80) return;

    final id = m['id'];
    if (id is! String || id.length > 40 || !_markSeen(id)) return;
    try {
      switch (m['t']) {
        case 'ann':
          await _onAnn(fromEndpoint, m);
          break;
        case 'pub':
          await _onPub(fromEndpoint, m);
          break;
        case 'dm':
          await _onDm(fromEndpoint, m);
          break;
      }
    } catch (_) {
      // A malformed message is dropped, never passed on.
    }
  }

  Future<void> _onAnn(String from, Map<String, dynamic> m) async {
    final uid = m['u'] as String;
    if (uid == _myUid) return;
    final key = _bytes(m['k'] as String);
    final x = _bytes(m['x'] as String);
    final ts = m['ts'] as int;
    if (key.length != 33 || x.length != 32) return;
    final sigOk = SignalSessionService.instance.verifyWithKey(key, _sigText('ann', [uid, m['x'] as String, '$ts']), _bytes(m['sig'] as String));
    if (!sigOk) return;
    // A person this phone knows can't be impersonated: their saved key must match.
    final pinned = await _pinnedState(uid, key);
    if (pinned == false) return;
    final existing = nodes[uid];
    if (existing != null && !listEquals(existing.idKey, key)) return; // first key seen wins
    final hops = (m['h'] as int?) ?? 0;
    final name = (m['n'] as String? ?? '').trim();
    final node = existing ?? MeshNode(uid, name.isEmpty ? 'nwisp user' : name.substring(0, min(name.length, 30)), key, x, pinned == true, hops + 1);
    node
      ..lastSeen = DateTime.now()
      ..hops = min(node.hops, hops + 1);
    // A fresh encryption key from the same person replaces the old one.
    if (existing != null && !listEquals(existing.xPub, x)) {
      nodes[uid] = MeshNode(uid, node.name, key, x, node.verified, node.hops);
    } else {
      nodes[uid] = node;
    }
    _flood(m, except: from);
    notifyListeners();
  }

  Future<void> _onPub(String from, Map<String, dynamic> m) async {
    final uid = m['u'] as String;
    final text = (m['x'] as String).trim();
    if (text.isEmpty || text.length > 500 || uid == _myUid) {
      _flood(m, except: from);
      return;
    }
    final key = _bytes(m['k'] as String);
    final ts = m['ts'] as int;
    final sigOk = key.length == 33 && SignalSessionService.instance.verifyWithKey(key, _sigText('pub', [m['id'] as String, uid, '$ts', text]), _bytes(m['sig'] as String));
    if (!sigOk) return; // tampered or forged — not shown, not passed on
    final pinned = await _pinnedState(uid, key);
    if (pinned == false) return;
    if (!muted.contains(uid)) {
      room.add(MeshMessage(
        id: m['id'] as String, fromUid: uid, fromName: ((m['n'] as String?) ?? 'nwisp user').substring(0, min(30, ((m['n'] as String?) ?? 'nwisp user').length)),
        text: text, mine: false, hops: (m['h'] as int?) ?? 0, verified: pinned == true,
      ));
      if (room.length > _maxRoom) room.removeAt(0);
      roomUnread++;
      notifyListeners();
    }
    _flood(m, except: from);
  }

  Future<void> _onDm(String from, Map<String, dynamic> m) async {
    final to = m['to'] as String;
    if (to != _myUid) {
      _flood(m, except: from); // not for me: pass it along unread
      return;
    }
    await _ensureKeys();
    final fromUid = m['from'] as String;
    final eph = _bytes(m['e'] as String);
    final raw = _bytes(m['c'] as String);
    if (eph.length != 32 || raw.length < 12 + 16) return;
    final shared = await _x25519.sharedSecretKey(keyPair: _kp!, remotePublicKey: SimplePublicKey(eph, type: KeyPairType.x25519));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode('NWisp-mesh-dm-salt-v1'),
      info: utf8.encode('NWisp-mesh-dm-v1|$fromUid|$to'),
    );
    final box = SecretBox(raw.sublist(12, raw.length - 16), nonce: raw.sublist(0, 12), mac: Mac(raw.sublist(raw.length - 16)));
    final clear = await _aes.decrypt(box, secretKey: key, aad: utf8.encode('$fromUid>$to|${m['id']}'));
    final j = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final text = (j['x'] as String).trim();
    final senderKey = _bytes(j['k'] as String);
    final ts = m['ts'] as int;
    final sigOk = senderKey.length == 33 && SignalSessionService.instance.verifyWithKey(senderKey, _sigText('dm', [fromUid, to, '$ts', text]), _bytes(j['sig'] as String));
    if (!sigOk || text.isEmpty || text.length > 1000) return;
    final pinned = await _pinnedState(fromUid, senderKey);
    if (pinned == false || muted.contains(fromUid)) return;
    final name = ((j['n'] as String?) ?? nodes[fromUid]?.name ?? 'nwisp user');
    threads.putIfAbsent(fromUid, () => []).add(MeshMessage(
      id: m['id'] as String, fromUid: fromUid, fromName: name.substring(0, min(30, name.length)),
      text: text, mine: false, hops: (m['h'] as int?) ?? 0, verified: pinned == true,
    ));
    unread[fromUid] = (unread[fromUid] ?? 0) + 1;
    notifyListeners();
  }

  // ------------------------------------------------------------ sending
  Future<void> sendPublic(String text) async {
    final uid = _myUid;
    final t = text.trim();
    if (uid == null || t.isEmpty || t.length > 500) return;
    final id = _newId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final key = await SignalSessionService.instance.myIdentityPublicKeyBytes();
    final sig = await SignalSessionService.instance.signWithIdentity(_sigText('pub', [id, uid, '$ts', t]));
    _markSeen(id);
    room.add(MeshMessage(id: id, fromUid: uid, fromName: _myName, text: t, mine: true, hops: 0, verified: true));
    notifyListeners();
    _sendOriginal({'t': 'pub', 'id': id, 'ttl': _pubTtl, 'h': 0, 'u': uid, 'n': _myName, 'k': base64Encode(key), 'x': t, 'ts': ts, 'sig': base64Encode(sig)});
  }

  Future<String?> sendDm(String toUid, String text) async {
    final uid = _myUid;
    final t = text.trim();
    final node = nodes[toUid];
    if (uid == null || t.isEmpty || t.length > 1000) return null;
    if (node == null) return 'This person is no longer reachable on the mesh.';
    final id = _newId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final myKey = await SignalSessionService.instance.myIdentityPublicKeyBytes();
    final sig = await SignalSessionService.instance.signWithIdentity(_sigText('dm', [uid, toUid, '$ts', t]));
    final eph = await _x25519.newKeyPair();
    final ephPub = Uint8List.fromList((await eph.extractPublicKey()).bytes);
    final shared = await _x25519.sharedSecretKey(keyPair: eph, remotePublicKey: SimplePublicKey(node.xPub, type: KeyPairType.x25519));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode('NWisp-mesh-dm-salt-v1'),
      info: utf8.encode('NWisp-mesh-dm-v1|$uid|$toUid'),
    );
    final nonce = List<int>.generate(12, (_) => _rand.nextInt(256));
    final plain = utf8.encode(jsonEncode({'x': t, 'n': _myName, 'k': base64Encode(myKey), 'sig': base64Encode(sig)}));
    final box = await _aes.encrypt(plain, secretKey: key, nonce: nonce, aad: utf8.encode('$uid>$toUid|$id'));
    _markSeen(id);
    threads.putIfAbsent(toUid, () => []).add(MeshMessage(id: id, fromUid: uid, fromName: _myName, text: t, mine: true, hops: 0, verified: true));
    notifyListeners();
    _sendOriginal({
      't': 'dm', 'id': id, 'ttl': _dmTtl, 'h': 0, 'from': uid, 'to': toUid, 'ts': ts,
      'e': base64Encode(ephPub), 'c': base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]),
    });
    return null;
  }

  void markRoomRead() {
    if (roomUnread != 0) {
      roomUnread = 0;
      notifyListeners();
    }
  }

  void markRead(String uid) {
    if ((unread[uid] ?? 0) != 0) {
      unread[uid] = 0;
      notifyListeners();
    }
  }

  void mute(String uid) {
    muted.add(uid);
    room.removeWhere((m) => m.fromUid == uid);
    threads.remove(uid);
    notifyListeners();
  }
}
