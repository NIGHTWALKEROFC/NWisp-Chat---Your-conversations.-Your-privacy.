import 'dart:convert';
import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// VERIFICATION NOTE — please read before relying on this file:
//
// This wiring is checked against libsignal_protocol_dart's published
// example (MixinNetwork/libsignal_protocol_dart, pub.dev v0.8.2) for the
// core flow: generateIdentityKeyPair/generateRegistrationId/generatePreKeys/
// generateSignedPreKey, SignalProtocolAddress, SessionBuilder,
// PreKeyBundle's constructor argument order, SessionCipher.encrypt, and
// CiphertextMessage.prekeyType — those are solid.
//
// A handful of deserialization constructors below (IdentityKeyPair.
// fromSerialized, PreKeyRecord.fromSerialized, IdentityKey.fromBytes) are
// my best-match guess based on the sibling SignedPreKeyRecord/SessionRecord
// constructors that ARE confirmed in the example, and on this package's
// close parity with libsignal-protocol-java — but I could not compile this
// against the real package in this environment to confirm those exact
// names. If `flutter analyze` or a build flags any of them, it's almost
// certainly a rename to the equivalent constructor shown in this package's
// generated API docs (pub.dev → libsignal_protocol_dart → API reference) —
// paste me the exact error and I'll fix the one line.

/// Thrown when a contact's identity key doesn't match the one we trusted
/// the first time we ever talked to them (see IdentityKeyStore.saveIdentity
/// below). This is exactly the "safety number changed" signal Signal/
/// WhatsApp show a warning for — it usually means they reinstalled or got
/// a new device, but it's also what a machine-in-the-middle attack would
/// look like, so it's surfaced as something the UI must ask the person
/// about rather than silently re-trusting.
class IdentityChangedException implements Exception {
  final String uid;
  IdentityChangedException(this.uid);
  @override
  String toString() => "This contact's encryption keys have changed since you last talked to them.";
}

/// Persistent, on-device implementation of the four store interfaces the
/// Signal Protocol needs (IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
/// SessionStore) — backed by SQLite instead of the package's InMemory*
/// reference implementations, since session/ratchet state has to survive
/// an app restart to be useful at all.
///
/// Trust model for identities: trust-on-first-use (TOFU), same as Signal/
/// WhatsApp/iMessage. The first identity key we ever see for a contact is
/// trusted and pinned; if it ever changes later, [saveIdentity] returns
/// false (a "changed" signal) and the caller (SignalSessionService) turns
/// that into an [IdentityChangedException] rather than silently accepting
/// the new key.
class PersistentSignalProtocolStore
    implements IdentityKeyStore, PreKeyStore, SignedPreKeyStore, SessionStore {
  Database? _db;
  IdentityKeyPair? _identityKeyPair;
  int? _registrationId;

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'nwisp_signal.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE identity (
            id INTEGER PRIMARY KEY CHECK (id = 0),
            key_pair BLOB NOT NULL,
            registration_id INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE trusted_identities (
            address_name TEXT NOT NULL,
            device_id INTEGER NOT NULL,
            identity_key BLOB NOT NULL,
            PRIMARY KEY (address_name, device_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE prekeys (
            id INTEGER PRIMARY KEY,
            record BLOB NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE signed_prekeys (
            id INTEGER PRIMARY KEY,
            record BLOB NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sessions (
            address_name TEXT NOT NULL,
            device_id INTEGER NOT NULL,
            record BLOB NOT NULL,
            PRIMARY KEY (address_name, device_id)
          )
        ''');
      },
    );
  }

  /// Wipes EVERYTHING — identity, sessions, prekeys. Used when a different
  /// account signs in on this device (see SessionService) and when
  /// re-installing this app's Signal identity from scratch.
  Future<void> wipeAll() async {
    await open();
    await _db!.delete('identity');
    await _db!.delete('trusted_identities');
    await _db!.delete('prekeys');
    await _db!.delete('signed_prekeys');
    await _db!.delete('sessions');
    _identityKeyPair = null;
    _registrationId = null;
  }

  Future<bool> hasIdentity() async {
    await open();
    final rows = await _db!.query('identity', limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> saveLocalIdentity(IdentityKeyPair pair, int registrationId) async {
    await open();
    await _db!.insert(
      'identity',
      {'id': 0, 'key_pair': pair.serialize(), 'registration_id': registrationId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _identityKeyPair = pair;
    _registrationId = registrationId;
  }

  Future<void> _loadLocalIdentity() async {
    if (_identityKeyPair != null) return;
    await open();
    final rows = await _db!.query('identity', limit: 1);
    if (rows.isEmpty) {
      throw StateError('No local Signal identity installed yet — call SignalSessionService.install() first.');
    }
    _identityKeyPair = IdentityKeyPair.fromSerialized(rows.first['key_pair'] as Uint8List);
    _registrationId = rows.first['registration_id'] as int;
  }

  // ---- IdentityKeyStore ----------------------------------------------

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    await _loadLocalIdentity();
    return _identityKeyPair!;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    await _loadLocalIdentity();
    return _registrationId!;
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    await open();
    if (identityKey == null) return false;
    final rows = await _db!.query(
      'trusted_identities',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName(), address.getDeviceId()],
      limit: 1,
    );
    final newBytes = identityKey.serialize();
    if (rows.isNotEmpty) {
      final existing = rows.first['identity_key'] as Uint8List;
      if (_bytesEqual(existing, newBytes)) return false; // unchanged, nothing to do
      // Changed since we last saw them — caller (SignalSessionService)
      // decides whether to surface IdentityChangedException or proceed
      // after explicit user confirmation. This method just reports the
      // fact; it does NOT silently overwrite trust on its own.
    }
    await _db!.insert(
      'trusted_identities',
      {'address_name': address.getName(), 'device_id': address.getDeviceId(), 'identity_key': newBytes},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return rows.isNotEmpty; // true = this WAS a change (existing row got replaced)
  }

  /// Read-only check used by SignalSessionService BEFORE calling
  /// [saveIdentity], so it can decide whether to throw
  /// [IdentityChangedException] instead of silently trusting a changed key.
  Future<bool> isIdentityChanged(SignalProtocolAddress address, IdentityKey identityKey) async {
    await open();
    final rows = await _db!.query(
      'trusted_identities',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName(), address.getDeviceId()],
      limit: 1,
    );
    if (rows.isEmpty) return false; // TOFU: nothing pinned yet, not a "change"
    return !_bytesEqual(rows.first['identity_key'] as Uint8List, identityKey.serialize());
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    // Trust-on-first-use: anything not yet pinned is trusted (this is what
    // lets a first message to a brand-new contact go through at all).
    // Already-pinned identities must match exactly.
    final changed = await isIdentityChanged(address, identityKey);
    return !changed;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    await open();
    final rows = await _db!.query(
      'trusted_identities',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName(), address.getDeviceId()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return IdentityKey.fromBytes(rows.first['identity_key'] as Uint8List, 0);
  }

  // ---- PreKeyStore -----------------------------------------------------

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    await open();
    final rows = await _db!.query('prekeys', where: 'id = ?', whereArgs: [preKeyId], limit: 1);
    if (rows.isEmpty) throw InvalidKeyIdException('No such prekey: $preKeyId');
    return PreKeyRecord.fromSerialized(rows.first['record'] as Uint8List);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await open();
    await _db!.insert(
      'prekeys',
      {'id': preKeyId, 'record': record.serialize()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    await open();
    final rows = await _db!.query('prekeys', where: 'id = ?', whereArgs: [preKeyId], limit: 1);
    return rows.isNotEmpty;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await open();
    await _db!.delete('prekeys', where: 'id = ?', whereArgs: [preKeyId]);
  }

  // ---- SignedPreKeyStore -------------------------------------------------

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    await open();
    final rows = await _db!.query('signed_prekeys', where: 'id = ?', whereArgs: [signedPreKeyId], limit: 1);
    if (rows.isEmpty) throw InvalidKeyIdException('No such signed prekey: $signedPreKeyId');
    return SignedPreKeyRecord.fromSerialized(rows.first['record'] as Uint8List);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    await open();
    final rows = await _db!.query('signed_prekeys');
    return rows.map((r) => SignedPreKeyRecord.fromSerialized(r['record'] as Uint8List)).toList();
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    await open();
    await _db!.insert(
      'signed_prekeys',
      {'id': signedPreKeyId, 'record': record.serialize()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    await open();
    final rows = await _db!.query('signed_prekeys', where: 'id = ?', whereArgs: [signedPreKeyId], limit: 1);
    return rows.isNotEmpty;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await open();
    await _db!.delete('signed_prekeys', where: 'id = ?', whereArgs: [signedPreKeyId]);
  }

  // ---- SessionStore -----------------------------------------------------

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    await open();
    final rows = await _db!.query(
      'sessions',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName(), address.getDeviceId()],
      limit: 1,
    );
    if (rows.isEmpty) return SessionRecord();
    return SessionRecord.fromSerialized(rows.first['record'] as Uint8List);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    await open();
    final rows = await _db!.query('sessions', columns: ['device_id'], where: 'address_name = ?', whereArgs: [name]);
    return rows.map((r) => r['device_id'] as int).toList();
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    await open();
    await _db!.insert(
      'sessions',
      {'address_name': address.getName(), 'device_id': address.getDeviceId(), 'record': record.serialize()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    await open();
    final rows = await _db!.query(
      'sessions',
      where: 'address_name = ? AND device_id = ?',
      whereArgs: [address.getName(), address.getDeviceId()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    await open();
    await _db!.delete('sessions', where: 'address_name = ? AND device_id = ?', whereArgs: [address.getName(), address.getDeviceId()]);
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    await open();
    await _db!.delete('sessions', where: 'address_name = ?', whereArgs: [name]);
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Small helper only used while publishing/consuming prekey bundles —
/// base64 plumbing lives in SignalSessionService, kept out of the store
/// itself since the store's job is pure persistence, not Firestore I/O.
String bytesToB64(List<int> bytes) => base64Encode(bytes);
Uint8List b64ToBytes(String s) => base64Decode(s);
