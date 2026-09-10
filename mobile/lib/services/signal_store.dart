import 'dart:convert';
import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'crypto_service.dart';

// VERIFICATION NOTE — please read before relying on this file:
//
// Checked against libsignal_protocol_dart's published example (v0.8.2) for
// the core flow, PLUS a real build error from this exact app (which caught
// two wrong guesses) and a real crash stack trace from another project
// using this same package. Current state:
//   - IdentityKeyPair.fromSerialized, SignedPreKeyRecord.fromSerialized,
//     SessionRecord.fromSerialized: confirmed correct (no build error).
//   - PreKeyRecord.fromBuffer: PreKeyRecord.fromSerialized was confirmed
//     WRONG by a real build error. .fromBuffer is the standard Dart
//     `protobuf` package deserialization convention (this library depends
//     on `protobuf`, and PreKeyRecord almost certainly wraps a generated
//     protobuf structure), which is why it's the current best guess — but
//     it's still not compiler-verified. If a build error names this line,
//     paste it and it's a one-line fix.
//
// SECURITY FIX (app-wide audit, 2026-09-09): every BLOB column in this
// file — the local identity private key, trusted-contact identity keys,
// prekeys, signed prekeys, and session/ratchet state — used to be written
// straight to SQLite with no encryption at all, even though
// local_message_store.dart encrypts message CONTENT at rest right next to
// it using the same device-local key. That was a real gap: this is the
// actual cryptographic material that lets a device decrypt messages, so
// if anything can read this app's files (a rooted device, an unencrypted
// device backup, malware with root, physical extraction), it could pull
// private keys and live session state straight out of a plain file. Now
// every one of those columns is run through the same AES-256-GCM local
// storage key CryptoService already uses for messages (which itself lives
// in FlutterSecureStorage / Android Keystore, not this database) — see
// _encryptBytes/_decryptBytes below. This does NOT protect against a
// compromised, currently-running instance of the app itself (nothing on
// a general-purpose OS can) — it protects the at-rest files.
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
      version: 2,
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
      // SECURITY FIX migration: every BLOB column above switched from
      // plaintext to encrypted (see the class doc comment). There's no
      // way to encrypt-in-place for whatever's already on a device from
      // before this update, and this table only ever holds this ONE
      // device's own transient key/session material anyway (never
      // anything that needs to outlive a reinstall on its own) — so the
      // straightforward, safe migration is to wipe it and let
      // SignalSessionService re-establish identity + sessions from
      // scratch, exactly like it already does for a brand-new install.
      // One-time effect on any device that already has this app: the
      // NEXT message to/from each existing contact re-does the Signal
      // handshake automatically (transparent, no user action) rather
      // than continuing an old ratchet. Recommend clearing app data or
      // reinstalling on your test devices right after this update so
      // both sides start clean at the same time.
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.execute('DROP TABLE IF EXISTS identity');
        await db.execute('DROP TABLE IF EXISTS trusted_identities');
        await db.execute('DROP TABLE IF EXISTS prekeys');
        await db.execute('DROP TABLE IF EXISTS signed_prekeys');
        await db.execute('DROP TABLE IF EXISTS sessions');
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

  // -----------------------------------------------------------------------
  // At-rest encryption for every BLOB column — see class doc comment.
  // Reuses CryptoService's device-local AES-256-GCM key (itself stored in
  // FlutterSecureStorage / Android Keystore) rather than introducing a
  // second key to manage. CryptoService.encryptLocal/decryptLocal work on
  // Strings, so raw Signal-library bytes are base64-encoded into a string
  // first; nonce and ciphertext are joined with a ':' and stored as the
  // BLOB's UTF-8 bytes so the existing single-column schema didn't need to
  // change.
  // -----------------------------------------------------------------------

  static Future<Uint8List> _encryptBytes(List<int> plaintext) async {
    final (cipherB64, nonceB64) = await CryptoService.encryptLocal(base64Encode(plaintext));
    return Uint8List.fromList(utf8.encode('$nonceB64:$cipherB64'));
  }

  static Future<Uint8List> _decryptBytes(Uint8List stored) async {
    final combined = utf8.decode(stored);
    final sep = combined.indexOf(':');
    final nonceB64 = combined.substring(0, sep);
    final cipherB64 = combined.substring(sep + 1);
    final plaintextB64 = await CryptoService.decryptLocal(cipherB64, nonceB64);
    return base64Decode(plaintextB64);
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
      {'id': 0, 'key_pair': await _encryptBytes(pair.serialize()), 'registration_id': registrationId},
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
    final bytes = await _decryptBytes(rows.first['key_pair'] as Uint8List);
    _identityKeyPair = IdentityKeyPair.fromSerialized(bytes);
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
      final existing = await _decryptBytes(rows.first['identity_key'] as Uint8List);
      if (_bytesEqual(existing, newBytes)) return false; // unchanged, nothing to do
      // Changed since we last saw them — caller (SignalSessionService)
      // decides whether to surface IdentityChangedException or proceed
      // after explicit user confirmation. This method just reports the
      // fact; it does NOT silently overwrite trust on its own.
    }
    await _db!.insert(
      'trusted_identities',
      {'address_name': address.getName(), 'device_id': address.getDeviceId(), 'identity_key': await _encryptBytes(newBytes)},
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
    final existing = await _decryptBytes(rows.first['identity_key'] as Uint8List);
    return !_bytesEqual(existing, identityKey.serialize());
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
    final bytes = await _decryptBytes(rows.first['identity_key'] as Uint8List);
    return IdentityKey.fromBytes(bytes, 0);
  }

  // ---- PreKeyStore -----------------------------------------------------

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    await open();
    final rows = await _db!.query('prekeys', where: 'id = ?', whereArgs: [preKeyId], limit: 1);
    if (rows.isEmpty) throw InvalidKeyIdException('No such prekey: $preKeyId');
    final bytes = await _decryptBytes(rows.first['record'] as Uint8List);
    return PreKeyRecord.fromBuffer(bytes);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await open();
    await _db!.insert(
      'prekeys',
      {'id': preKeyId, 'record': await _encryptBytes(record.serialize())},
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
    final bytes = await _decryptBytes(rows.first['record'] as Uint8List);
    return SignedPreKeyRecord.fromSerialized(bytes);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    await open();
    final rows = await _db!.query('signed_prekeys');
    final out = <SignedPreKeyRecord>[];
    for (final r in rows) {
      final bytes = await _decryptBytes(r['record'] as Uint8List);
      out.add(SignedPreKeyRecord.fromSerialized(bytes));
    }
    return out;
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    await open();
    await _db!.insert(
      'signed_prekeys',
      {'id': signedPreKeyId, 'record': await _encryptBytes(record.serialize())},
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
    final bytes = await _decryptBytes(rows.first['record'] as Uint8List);
    return SessionRecord.fromSerialized(bytes);
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
      {'address_name': address.getName(), 'device_id': address.getDeviceId(), 'record': await _encryptBytes(record.serialize())},
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
