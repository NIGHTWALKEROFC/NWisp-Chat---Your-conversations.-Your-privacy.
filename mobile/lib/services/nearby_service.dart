import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mesh_service.dart';
import 'signal_session_service.dart';

enum NearbyMode { friends, everyone }

enum PeerState { found, requesting, incoming, connecting, connected, declined }

class NearbyMessage {
  final bool mine;
  final String text;
  final DateTime at;
  NearbyMessage(this.mine, this.text) : at = DateTime.now();
}

/// Someone nearby. Everything about them lives in memory only.
class NearbyPeer {
  final String endpointId;
  String claimedName; // what they advertise — NOT proof of who they are
  PeerState state = PeerState.found;
  bool isFriend = false;
  /// null = not checked yet, true = proven (their key matches the one saved
  /// from earlier chats), false = could not be proven.
  bool? verified;
  /// A relay link for the mesh network (not a chat) — see MeshService.
  bool mesh = false;
  String? uid;
  List<int>? myNonce;
  List<int>? theirNonce;
  Uint8List? theirKey;
  String? theirUid;
  bool sentAuth = false;
  final List<NearbyMessage> messages = [];
  int unread = 0;
  NearbyPeer(this.endpointId, this.claimedName);
}

/// Feature: Nearby chat — talk to people close by with no internet, over
/// Bluetooth and Wi-Fi (Google's Nearby Connections, Android only), in the
/// spirit of bitchat. This is a separate, temporary space:
///   * nothing is saved — messages exist only in memory and vanish when the
///     connection closes or the app is closed,
///   * it never touches the normal chat list or the servers,
///   * scanning is OFF until you switch it on.
///
/// Who you're talking to is checked after connecting: each side signs a fresh
/// challenge with its NWisp identity key, and "Verified" appears only if that
/// key matches the one this phone saved from earlier chats with that person.
/// Anyone else shows as "Unverified" — they may be using a name they don't own.
/// The radio link itself is encrypted by Nearby Connections.
class NearbyService extends ChangeNotifier {
  NearbyService._();
  static final instance = NearbyService._();

  static const _serviceId = 'com.nightwalker.securechat.nearby';
  static const _strategy = Strategy.P2P_CLUSTER;
  static const _kMode = 'nearby_mode';
  static const _kMesh = 'nearby_mesh';
  static const _maxMeshLinks = 5;
  static const _prefix = 'NW|';

  final _nearby = Nearby();
  final _rand = Random.secure();

  NearbyMode mode = NearbyMode.friends;

  /// Feature: mesh relay. When on, this phone links to other mesh phones
  /// automatically and passes public-room messages and encrypted direct
  /// messages along, so people further than one radio hop can still talk.
  bool meshEnabled = false;
  bool scanning = false;
  bool busy = false;
  String? error;
  String myName = '';
  final Map<String, NearbyPeer> peers = {};
  /// username (lowercase) -> uid, for my contacts.
  final Map<String, String> friends = {};
  StreamSubscription? _friendsSub;
  bool _loaded = false;

  /// Contacts' identity keys, fetched while online so they can still be
  /// checked later with no internet.
  final Map<String, Uint8List> _keyCache = {};

  /// Set when someone asks to connect, so the screen can show a prompt.
  final ValueNotifier<NearbyPeer?> incomingRequest = ValueNotifier<NearbyPeer?>(null);

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    mode = (p.getString(_kMode) == 'everyone') ? NearbyMode.everyone : NearbyMode.friends;
    meshEnabled = p.getBool(_kMesh) ?? false;
    _loaded = true;
    final uid = _myUid;
    if (uid != null) {
      try {
        final me = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        myName = (me.data()?['username'] as String?) ?? '';
      } catch (_) {}
      _friendsSub?.cancel();
      _friendsSub = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('contacts')
          .snapshots()
          .listen((snap) {
        friends
          ..clear()
          ..addEntries(snap.docs.map((d) => MapEntry(((d.data()['username'] as String?) ?? '').toLowerCase(), d.id)));
        notifyListeners();
      }, onError: (_) {});
    }
  }

  Future<void> setMesh(bool on) async {
    meshEnabled = on;
    (await SharedPreferences.getInstance()).setBool(_kMesh, on);
    if (!on) {
      // Drop the relay links; chat connections stay.
      for (final p in peers.values.where((p) => p.mesh).toList()) {
        await disconnect(p);
      }
      MeshService.instance.reset();
    }
    // The advertised name tells others whether this phone relays, so restart.
    if (scanning) {
      await stop();
      await start();
    } else {
      notifyListeners();
    }
  }

  String get _advName => '$_prefix${myName.isEmpty ? 'nwisp' : myName}${meshEnabled ? '|m' : ''}';

  /// Names look like "NW|alice", "NW|alice|m" (this phone relays) or
  /// "NW|alice|L" (a relay link request, not a chat request).
  ({String name, String flag}) _parseName(String endpointName) {
    final parts = endpointName.split('|');
    if (parts.isEmpty || parts[0] != 'NW') return (name: endpointName, flag: '');
    return (name: parts.length > 1 ? parts[1] : '', flag: parts.length > 2 ? parts[2] : '');
  }

  int get meshLinkCount => peers.values.where((p) => p.mesh).length;
  List<NearbyPeer> get meshLinks => peers.values.where((p) => p.mesh && p.state == PeerState.connected).toList();

  /// Sends a mesh message to one linked phone.
  void sendRaw(String endpointId, Map<String, dynamic> json) => _sendBytes(endpointId, json);

  Future<void> setMode(NearbyMode m) async {
    mode = m;
    (await SharedPreferences.getInstance()).setString(_kMode, m == NearbyMode.everyone ? 'everyone' : 'friends');
    // Switching modes restarts the search so the list matches.
    if (scanning) {
      await stop();
      await start();
    } else {
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ permissions
  /// Everything Nearby needs, as a checklist for the screen.
  Future<Map<String, bool>> checklist() async {
    final bt = await Permission.bluetoothScan.status.isGranted &&
        await Permission.bluetoothAdvertise.status.isGranted &&
        await Permission.bluetoothConnect.status.isGranted;
    return {
      'permissions': bt && await Permission.locationWhenInUse.status.isGranted,
      'location': await Permission.locationWhenInUse.serviceStatus.isEnabled,
    };
  }

  Future<bool> requestPermissions() async {
    final results = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
    ].request();
    // nearbyWifiDevices only exists on Android 13+ — "denied" there is fine on older phones.
    final needed = [Permission.bluetoothScan, Permission.bluetoothAdvertise, Permission.bluetoothConnect, Permission.locationWhenInUse];
    return needed.every((p) => results[p]?.isGranted == true || results[p]?.isLimited == true);
  }

  // ------------------------------------------------------------ scanning
  Future<void> start() async {
    if (scanning || busy) return;
    await load();
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!await requestPermissions()) {
        error = 'Nearby needs Bluetooth and location permission. Allow them in the next prompt or in Android settings.';
        return;
      }
      final c = await checklist();
      if (c['location'] != true) {
        error = 'Turn on Location (Android needs it to find nearby phones). Nothing about your location is used or stored.';
        return;
      }
      // While there is still internet, remember my contacts' security keys.
      await _prefetchFriendKeys().timeout(const Duration(seconds: 6), onTimeout: () {});
      final name = _advName;
      await _nearby.startAdvertising(
        name,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
      await _nearby.startDiscovery(
        name,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: _onFound,
        onEndpointLost: (id) {
          final p = peers[id];
          if (p != null && p.state == PeerState.found) {
            peers.remove(id);
            notifyListeners();
          }
        },
      );
      scanning = true;
    } catch (e) {
      error = "Couldn't start scanning. Make sure Bluetooth, Wi-Fi and Location are switched on, then try again.";
      try {
        await _nearby.stopAdvertising();
        await _nearby.stopDiscovery();
      } catch (_) {}
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stop({bool disconnect = false}) async {
    try {
      await _nearby.stopAdvertising();
      await _nearby.stopDiscovery();
    } catch (_) {}
    scanning = false;
    peers.removeWhere((_, p) => p.state == PeerState.found || p.state == PeerState.declined);
    if (disconnect) await disconnectAll();
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    peers.clear();
    incomingRequest.value = null;
    notifyListeners();
  }

  Future<void> _prefetchFriendKeys() async {
    for (final uid in friends.values.take(100)) {
      if (_keyCache.containsKey(uid)) continue;
      try {
        final k = await SignalSessionService.instance.peerIdentityPublicKeyBytes(uid);
        if (k != null) _keyCache[uid] = k;
      } catch (_) {
        // Offline: whatever is already saved on this phone is used instead.
      }
    }
  }

  // ------------------------------------------------------------ discovery
  void _onFound(String id, String endpointName, String serviceId) {
    if (!endpointName.startsWith(_prefix)) return;
    final parsed = _parseName(endpointName);
    final claimed = parsed.name;
    if (claimed.isEmpty) return;
    final lower = claimed.toLowerCase();
    final isFriend = friends.containsKey(lower);
    // Mesh: another relaying phone — link to it (the phone with the smaller
    // name makes the request, so both don't ask at once).
    if (meshEnabled && parsed.flag == 'm' && !peers.containsKey(id) && meshLinkCount < _maxMeshLinks &&
        _myLower.compareTo(lower) < 0) {
      _requestMeshLink(id, claimed);
      return;
    }
    if (parsed.flag == 'm' && peers[id]?.mesh == true) return;
    if (mode == NearbyMode.friends && !isFriend) return; // not shown at all
    final p = peers.putIfAbsent(id, () => NearbyPeer(id, claimed));
    p.claimedName = claimed;
    p.isFriend = isFriend;
    notifyListeners();
  }

  String get _myLower => (myName.isEmpty ? 'nwisp' : myName).toLowerCase();

  Future<void> _requestMeshLink(String id, String claimed) async {
    final p = NearbyPeer(id, claimed)
      ..mesh = true
      ..state = PeerState.requesting;
    peers[id] = p;
    notifyListeners();
    try {
      await _nearby.requestConnection(
        '$_prefix${myName.isEmpty ? 'nwisp' : myName}|L',
        id,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
    } catch (_) {
      peers.remove(id);
      notifyListeners();
    }
  }

  Future<void> request(NearbyPeer p) async {
    p.state = PeerState.requesting;
    notifyListeners();
    try {
      await _nearby.requestConnection(
        '$_prefix${myName.isEmpty ? 'nwisp' : myName}',
        p.endpointId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
    } catch (_) {
      p.state = PeerState.found;
      error = "Couldn't reach ${p.claimedName}.";
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ connection
  void _onInitiated(String id, ConnectionInfo info) {
    final parsed = _parseName(info.endpointName);
    final claimed = parsed.name;
    // A relay link request is not a chat request.
    if (info.isIncomingConnection && parsed.flag == 'L') {
      if (!meshEnabled || (peers[id]?.mesh != true && meshLinkCount >= _maxMeshLinks)) {
        _nearby.rejectConnection(id);
        return;
      }
      final mp = peers.putIfAbsent(id, () => NearbyPeer(id, claimed));
      mp
        ..claimedName = claimed
        ..mesh = true
        ..state = PeerState.connecting;
      _accept(id);
      notifyListeners();
      return;
    }
    final p = peers.putIfAbsent(id, () => NearbyPeer(id, claimed));
    p.claimedName = claimed;
    p.isFriend = friends.containsKey(claimed.toLowerCase());
    if (info.isIncomingConnection) {
      // Someone asked to connect to me.
      if (mode == NearbyMode.friends && !p.isFriend) {
        _nearby.rejectConnection(id);
        peers.remove(id);
        return;
      }
      p.state = PeerState.incoming;
      incomingRequest.value = p;
    } else {
      // I asked and they accepted on their side — accept here too.
      p.state = PeerState.connecting;
      _accept(id);
    }
    notifyListeners();
  }

  Future<void> accept(NearbyPeer p) async {
    if (incomingRequest.value == p) incomingRequest.value = null;
    p.state = PeerState.connecting;
    notifyListeners();
    await _accept(p.endpointId);
  }

  Future<void> decline(NearbyPeer p) async {
    if (incomingRequest.value == p) incomingRequest.value = null;
    try {
      await _nearby.rejectConnection(p.endpointId);
    } catch (_) {}
    peers.remove(p.endpointId);
    notifyListeners();
  }

  Future<void> _accept(String id) async {
    try {
      await _nearby.acceptConnection(
        id,
        onPayLoadRecieved: (endpointId, payload) {
          if (payload.type == PayloadType.BYTES && payload.bytes != null) _onBytes(endpointId, payload.bytes!);
        },
        onPayloadTransferUpdate: (_, __) {},
      );
    } catch (_) {
      peers.remove(id);
      notifyListeners();
    }
  }

  void _onResult(String id, Status status) {
    final p = peers[id];
    if (p == null) return;
    if (status == Status.CONNECTED) {
      p.state = PeerState.connected;
      if (p.mesh) {
        MeshService.instance.onLinkUp(id);
      } else {
        _sendHello(p);
      }
    } else {
      p.state = status == Status.REJECTED ? PeerState.declined : PeerState.found;
      if (status != Status.REJECTED) peers.remove(id);
    }
    notifyListeners();
  }

  void _onDisconnected(String id) {
    final p = peers[id];
    if (p == null) return;
    // Everything said in this chat goes with it.
    peers.remove(id);
    if (incomingRequest.value == p) incomingRequest.value = null;
    notifyListeners();
  }

  Future<void> disconnect(NearbyPeer p) async {
    try {
      await _nearby.disconnectFromEndpoint(p.endpointId);
    } catch (_) {}
    peers.remove(p.endpointId);
    notifyListeners();
  }

  // ------------------------------------------------------------ identity check
  List<int> _nonce() => List<int>.generate(16, (_) => _rand.nextInt(256));

  void _sendBytes(String id, Map<String, dynamic> json) {
    try {
      _nearby.sendBytesPayload(id, Uint8List.fromList(utf8.encode(jsonEncode(json))));
    } catch (_) {}
  }

  Future<void> _sendHello(NearbyPeer p) async {
    final uid = _myUid;
    if (uid == null) return;
    p.myNonce = _nonce();
    final key = await SignalSessionService.instance.myIdentityPublicKeyBytes();
    _sendBytes(p.endpointId, {'t': 'hello', 'u': myName, 'id': uid, 'k': base64Encode(key), 'n': base64Encode(p.myNonce!)});
  }

  Uint8List _challenge(List<int> nonce, String signerUid) =>
      Uint8List.fromList(utf8.encode('NWisp-nearby-v1|') + nonce + utf8.encode('|$signerUid'));

  Future<void> _onBytes(String id, Uint8List bytes) async {
    final p = peers[id];
    if (p == null) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // Mesh links only carry mesh traffic; chat links never do.
    if (p.mesh) {
      MeshService.instance.onBytes(id, m);
      return;
    }
    switch (m['t']) {
      case 'hello':
        try {
          p.theirUid = m['id'] as String;
          p.theirKey = base64Decode(m['k'] as String);
          p.theirNonce = base64Decode(m['n'] as String);
          final u = (m['u'] as String?) ?? '';
          if (u.isNotEmpty) p.claimedName = u;
          final myUid = _myUid;
          if (myUid != null && !p.sentAuth) {
            p.sentAuth = true;
            // Prove I hold my identity key: sign THEIR fresh challenge.
            final sig = await SignalSessionService.instance.signWithIdentity(_challenge(p.theirNonce!, myUid));
            _sendBytes(id, {'t': 'auth', 'sig': base64Encode(sig)});
          }
        } catch (_) {}
        break;
      case 'auth':
        await _verify(p, base64Decode(m['sig'] as String));
        break;
      case 'msg':
        final text = (m['x'] as String?) ?? '';
        if (text.isEmpty || text.length > 2000) return;
        // Messages before the identity check finishes are ignored in friends mode.
        if (mode == NearbyMode.friends && p.verified != true) return;
        p.messages.add(NearbyMessage(false, text));
        p.unread++;
        notifyListeners();
        break;
    }
  }

  Future<void> _verify(NearbyPeer p, Uint8List sig) async {
    final theirUid = p.theirUid;
    final key = p.theirKey;
    final nonce = p.myNonce;
    if (theirUid == null || key == null || nonce == null) {
      p.verified = false;
    } else {
      bool signatureOk = false;
      try {
        signatureOk = SignalSessionService.instance.verifyWithKey(key, _challenge(nonce, theirUid), sig);
      } catch (_) {}
      // The proof only counts if this phone already knew that key for that
      // person — from earlier chats, or saved for a contact while online —
      // so the check works with no internet.
      final pinned = await SignalSessionService.instance.pinnedPeerIdentityKey(theirUid) ?? _keyCache[theirUid];
      final matches = pinned != null && listEquals(pinned, key);
      final friendUid = friends[p.claimedName.toLowerCase()];
      p.verified = signatureOk && matches && (friendUid == null || friendUid == theirUid);
      p.uid = p.verified == true ? theirUid : null;
    }
    if (mode == NearbyMode.friends && p.verified != true) {
      error = "Couldn't confirm ${p.claimedName} is who they say, so the connection was closed.";
      await disconnect(p);
      return;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ chat
  Future<void> sendText(NearbyPeer p, String text) async {
    final t = text.trim();
    if (t.isEmpty || p.state != PeerState.connected) return;
    if (mode == NearbyMode.friends && p.verified != true) return;
    p.messages.add(NearbyMessage(true, t));
    _sendBytes(p.endpointId, {'t': 'msg', 'x': t});
    notifyListeners();
  }

  void markRead(NearbyPeer p) {
    if (p.unread != 0) {
      p.unread = 0;
      notifyListeners();
    }
  }

  /// Everything wiped (used when signing out).
  Future<void> reset() async {
    MeshService.instance.reset();
    await stop(disconnect: true);
    _friendsSub?.cancel();
    friends.clear();
    _keyCache.clear();
    _loaded = false;
  }
}
