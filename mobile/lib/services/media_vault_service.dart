import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';

import 'app_lock_service.dart';
import 'biometric_unlock_service.dart';

/// How the vault is opened.
///  * [pin]       — its own PIN (never the app PIN, never biometrics). Can be
///                  reset by re-entering the ACCOUNT password.
///  * [biometric] — fingerprint/face ONLY. The PIN is deleted and there is no
///                  reset path at all, so knowing the account password gets
///                  someone nothing.
enum VaultMode { pin, biometric }

/// One photo or video in the vault. Only this small description is kept in
/// the (encrypted) index — the media itself lives in its own encrypted file.
class VaultItem {
  final String id;
  final String kind; // 'image' | 'video'
  final String ext; // 'jpg', 'mp4', ...
  final int size; // original size in bytes
  final DateTime addedAt;
  final bool hasThumb;

  const VaultItem({
    required this.id,
    required this.kind,
    required this.ext,
    required this.size,
    required this.addedAt,
    required this.hasThumb,
  });

  bool get isVideo => kind == 'video';

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'ext': ext,
        'size': size,
        'addedAt': addedAt.millisecondsSinceEpoch,
        'hasThumb': hasThumb,
      };

  factory VaultItem.fromJson(Map<String, dynamic> j) => VaultItem(
        id: j['id'] as String,
        kind: j['kind'] as String,
        ext: j['ext'] as String,
        size: (j['size'] as num).toInt(),
        addedAt: DateTime.fromMillisecondsSinceEpoch((j['addedAt'] as num).toInt()),
        hasThumb: j['hasThumb'] == true,
      );
}

/// Result of trying a vault PIN.
class VaultPinResult {
  final bool ok;

  /// Set when too many wrong tries have locked the PIN pad for a while.
  final Duration? lockedFor;

  /// Wrong tries left before the next short lock (only meaningful if !ok).
  final int attemptsLeft;

  const VaultPinResult({required this.ok, this.lockedFor, this.attemptsLeft = 0});
}

/// Feature: locked media vault — everything that isn't screens.
///
/// HOW IT PROTECTS THINGS
///  * Every photo/video is encrypted on disk with AES-256-GCM in 1 MB pieces
///    (so big videos never have to fit in memory), each piece authenticated,
///    so a tampered or truncated file is detected rather than half-opened.
///  * The encryption key is random, generated once at setup, and lives in
///    Android Keystore-backed secure storage. It is NOT derived from the PIN
///    — that's what lets "reset via account password" keep your media.
///  * The PIN (4-8 digits) is stored only as a salted PBKDF2 hash and gates
///    access inside the app, with escalating lock-outs after wrong tries.
///  * In biometric-only mode the PIN hash is deleted outright and
///    [resetPin] refuses to work.
///
/// HONEST LIMITS
///  * The PIN/biometric check is an access gate inside the app, not a second
///    layer of encryption. Someone who has already broken into the phone's
///    hardware-backed key storage (rooted device, forensic tooling) is
///    outside what any app-level vault can stop.
///  * A photo being viewed or played is decrypted to a temporary file until
///    it's closed (needed for video playback); those temporary files are
///    deleted on close, on lock, and at every start.
class MediaVaultService {
  MediaVaultService._();
  static final instance = MediaVaultService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _keyMaster = 'vault_master_key';
  static const _keyPinHash = 'vault_pin_hash';
  static const _keyPinSalt = 'vault_pin_salt';
  static const _keyMode = 'vault_mode';
  static const _keyFails = 'vault_fail_count';
  static const _keyLockUntil = 'vault_lock_until_ms';

  static const int minPinLength = 4;
  static const int maxPinLength = 8;
  static const int _chunkSize = 1024 * 1024;
  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static const List<int> _magic = [0x4E, 0x57, 0x56, 0x31]; // "NWV1"

  static final _aes = AesGcm.with256bits();
  static final _pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 30000, bits: 256);
  static const _uuid = Uuid();

  bool _unlocked = false;
  SecretKey? _cachedKey; // only kept while unlocked
  final Map<String, Uint8List> _thumbCache = {};
  Future<void> _tail = Future.value();

  bool get isUnlocked => _unlocked;

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------

  Future<bool> isSetUp() async => (await _storage.read(key: _keyMaster)) != null;

  /// null = the vault hasn't been set up yet.
  Future<VaultMode?> mode() async {
    if (!await isSetUp()) return null;
    return (await _storage.read(key: _keyMode)) == 'biometric' ? VaultMode.biometric : VaultMode.pin;
  }

  /// Why [pin] can't be used as a NEW vault PIN, or null if it's fine.
  /// It must be 4-8 digits and must not be the same as the app PIN, so
  /// someone who has watched the app PIN being typed still can't open the
  /// vault with it.
  Future<String?> newPinProblem(String pin) async {
    if (!RegExp(r'^\d+$').hasMatch(pin)) return 'Use digits only.';
    if (pin.length < minPinLength) return 'Use at least $minPinLength digits.';
    if (pin.length > maxPinLength) return 'Use at most $maxPinLength digits.';
    if (await AppLockService.verify(pin)) {
      return 'That is the same as your app PIN — choose a different one for the vault.';
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Setup / unlock / lock
  // ------------------------------------------------------------------

  Future<void> setUp(String pin) async {
    final problem = await newPinProblem(pin);
    if (problem != null) throw ArgumentError(problem);
    final key = await _aes.newSecretKey();
    final keyBytes = await key.extractBytes();
    await _storage.write(key: _keyMaster, value: base64Encode(keyBytes));
    await _writePin(pin);
    await _storage.write(key: _keyMode, value: 'pin');
    await _clearFailures();
    await _vaultDir();
    _unlocked = true;
    _cachedKey = SecretKey(keyBytes);
  }

  /// Tries the vault PIN. Never works in biometric-only mode (there is no
  /// PIN then). Wrong tries are counted and lock the pad for escalating
  /// periods: after every 5th wrong try, 30 s, then 60 s, 2 min ... up to 1 h.
  Future<VaultPinResult> unlockWithPin(String pin) async {
    if (await mode() != VaultMode.pin) return const VaultPinResult(ok: false);
    final lockedFor = await _lockoutRemaining();
    if (lockedFor != null) return VaultPinResult(ok: false, lockedFor: lockedFor);

    if (await _pinMatches(pin)) {
      await _clearFailures();
      _unlocked = true;
      return const VaultPinResult(ok: true);
    }

    final fails = (int.tryParse(await _storage.read(key: _keyFails) ?? '0') ?? 0) + 1;
    await _storage.write(key: _keyFails, value: fails.toString());
    if (fails % 5 == 0) {
      final tier = fails ~/ 5;
      final seconds = min(3600, 30 * pow(2, tier - 1).toInt());
      await _storage.write(
        key: _keyLockUntil,
        value: DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch.toString(),
      );
      return VaultPinResult(ok: false, lockedFor: Duration(seconds: seconds));
    }
    return VaultPinResult(ok: false, attemptsLeft: 5 - (fails % 5));
  }

  /// Opens the vault with fingerprint/face. Only valid in biometric-only mode.
  Future<bool> unlockWithBiometric() async {
    if (await mode() != VaultMode.biometric) return false;
    final ok = await BiometricUnlockService.authenticate(reason: 'Open your media vault');
    if (ok) _unlocked = true;
    return ok;
  }

  /// Re-locks the vault and clears everything decrypted from memory/disk.
  void lock() {
    _unlocked = false;
    _cachedKey = null;
    _thumbCache.clear();
    cleanTemp();
  }

  // ------------------------------------------------------------------
  // PIN management
  // ------------------------------------------------------------------

  /// Sets a NEW vault PIN while KEEPING everything in the vault.
  ///
  /// The caller is responsible for having just proved who's asking:
  ///  * "Forgot PIN"  -> the ACCOUNT password was re-checked with Firebase.
  ///  * "Change PIN"  -> the current PIN was just entered.
  /// Refuses outright in biometric-only mode: that mode has no reset path.
  Future<void> resetPin(String newPin) async {
    if (await mode() != VaultMode.pin) {
      throw StateError('The vault PIN cannot be reset in biometric-only mode.');
    }
    final problem = await newPinProblem(newPin);
    if (problem != null) throw ArgumentError(problem);
    await _writePin(newPin);
    await _clearFailures();
    _unlocked = true;
  }

  /// Switches to biometric-only: proves biometrics work RIGHT NOW (one prompt),
  /// then permanently deletes the PIN. Must already be unlocked.
  Future<bool> enableBiometricOnly() async {
    if (!_unlocked || await mode() != VaultMode.pin) return false;
    final ok = await BiometricUnlockService.authenticate(reason: 'Confirm biometric-only vault unlock');
    if (!ok) return false;
    await _storage.delete(key: _keyPinHash);
    await _storage.delete(key: _keyPinSalt);
    await _storage.write(key: _keyMode, value: 'biometric');
    await _clearFailures();
    return true;
  }

  /// Leaves biometric-only mode: another biometric check, then a fresh PIN.
  Future<bool> disableBiometricOnly(String newPin) async {
    if (!_unlocked || await mode() != VaultMode.biometric) return false;
    final problem = await newPinProblem(newPin);
    if (problem != null) throw ArgumentError(problem);
    final ok = await BiometricUnlockService.authenticate(reason: 'Confirm turning biometric-only unlock off');
    if (!ok) return false;
    await _writePin(newPin);
    await _storage.write(key: _keyMode, value: 'pin');
    await _clearFailures();
    return true;
  }

  // ------------------------------------------------------------------
  // Contents
  // ------------------------------------------------------------------

  /// Adds a photo/video to the vault. Works whenever the vault is set up —
  /// adding needs the key but doesn't reveal anything, so it doesn't need the
  /// vault to be unlocked (that's what lets "Move to vault" in a chat be one
  /// tap). The source file is left untouched; the caller removes it.
  Future<VaultItem> importFile(File source, {required bool isVideo, String? extension}) {
    return _serial(() async {
      if (!await isSetUp()) throw StateError('The vault is not set up.');
      final key = await _masterKey();
      final id = _uuid.v4();
      final ext = _cleanExt(extension ?? p.extension(source.path), isVideo);
      final dir = await _vaultDir();
      final size = await source.length();

      await _encryptFile(source, File(p.join(dir.path, '$id.bin')), key);

      var hasThumb = false;
      final thumb = await _makeThumb(source, isVideo);
      if (thumb != null) {
        await File(p.join(dir.path, '$id.thumb')).writeAsBytes(await _seal(thumb, key), flush: true);
        hasThumb = true;
      }

      final item = VaultItem(
        id: id,
        kind: isVideo ? 'video' : 'image',
        ext: ext,
        size: size,
        addedAt: DateTime.now(),
        hasThumb: hasThumb,
      );
      final items = await _readIndex(key);
      items.add(item);
      await _writeIndex(items, key);
      return item;
    });
  }

  Future<List<VaultItem>> listItems() async {
    _requireUnlocked();
    final key = await _masterKey();
    final items = await _readIndex(key);
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return items;
  }

  Future<Uint8List?> thumbnail(VaultItem item) async {
    _requireUnlocked();
    if (!item.hasThumb) return null;
    final cached = _thumbCache[item.id];
    if (cached != null) return cached;
    try {
      final key = await _masterKey();
      final dir = await _vaultDir();
      final file = File(p.join(dir.path, '${item.id}.thumb'));
      if (!await file.exists()) return null;
      final bytes = await _open(await file.readAsBytes(), key);
      _thumbCache[item.id] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Decrypts one item to a temporary file so it can be shown/played. The
  /// caller must delete the returned file when finished (the vault screen
  /// does); anything left over is swept on lock and at startup.
  Future<File> decryptToTemp(VaultItem item) async {
    _requireUnlocked();
    final key = await _masterKey();
    final dir = await _vaultDir();
    final tmp = await _tempDir();
    final out = File(p.join(tmp.path, '${item.id}.${item.ext}'));
    await _decryptFile(File(p.join(dir.path, '${item.id}.bin')), out, key);
    return out;
  }

  Future<void> deleteItems(List<String> ids) {
    return _serial(() async {
      _requireUnlocked();
      final key = await _masterKey();
      final dir = await _vaultDir();
      final items = await _readIndex(key);
      for (final id in ids) {
        for (final suffix in const ['bin', 'thumb']) {
          try {
            final f = File(p.join(dir.path, '$id.$suffix'));
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        _thumbCache.remove(id);
      }
      items.removeWhere((i) => ids.contains(i.id));
      await _writeIndex(items, key);
    });
  }

  /// Deletes the whole vault: every file, the key, the PIN — everything.
  /// Also called automatically when a different account signs in on this
  /// phone (see LocalMessageStore.resetForNewUser). Safe to call any time,
  /// including when no vault exists.
  Future<void> wipeAll() async {
    _unlocked = false;
    _cachedKey = null;
    _thumbCache.clear();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'vault'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    await cleanTemp();
    for (final k in const [_keyMaster, _keyPinHash, _keyPinSalt, _keyMode, _keyFails, _keyLockUntil]) {
      try {
        await _storage.delete(key: k);
      } catch (_) {}
    }
  }

  /// Removes any decrypted temporary copies.
  Future<void> cleanTemp() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'vault_tmp'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  void _requireUnlocked() {
    if (!_unlocked) throw StateError('The vault is locked.');
  }

  /// Runs vault file/index changes one at a time so two quick imports can
  /// never overwrite each other's index update.
  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<SecretKey> _masterKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final b64 = await _storage.read(key: _keyMaster);
    if (b64 == null) throw StateError('The vault is not set up.');
    final key = SecretKey(base64Decode(b64));
    if (_unlocked) _cachedKey = key;
    return key;
  }

  Future<Directory> _vaultDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'vault'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _tempDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'vault_tmp'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _cleanExt(String raw, bool isVideo) {
    final e = raw.toLowerCase().replaceAll('.', '');
    if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(e)) return e;
    return isVideo ? 'mp4' : 'jpg';
  }

  // ---- PIN hashing ---------------------------------------------------

  Future<String> _derive(String pin, List<int> salt) async {
    final k = await _pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
    return base64Encode(await k.extractBytes());
  }

  Future<void> _writePin(String pin) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    await _storage.write(key: _keyPinSalt, value: base64Encode(salt));
    await _storage.write(key: _keyPinHash, value: await _derive(pin, salt));
  }

  Future<bool> _pinMatches(String pin) async {
    final saltB64 = await _storage.read(key: _keyPinSalt);
    final stored = await _storage.read(key: _keyPinHash);
    if (saltB64 == null || stored == null) return false;
    final candidate = await _derive(pin, base64Decode(saltB64));
    return _constantTimeEquals(candidate, stored);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Duration?> _lockoutRemaining() async {
    final raw = await _storage.read(key: _keyLockUntil);
    if (raw == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(int.tryParse(raw) ?? 0);
    final left = until.difference(DateTime.now());
    return left > Duration.zero ? left : null;
  }

  Future<void> _clearFailures() async {
    await _storage.delete(key: _keyFails);
    await _storage.delete(key: _keyLockUntil);
  }

  // ---- Encryption ----------------------------------------------------

  Uint8List _aad(int index) {
    final b = ByteData(8)..setUint64(0, index);
    return b.buffer.asUint8List();
  }

  /// Small blobs (thumbnails, the index): one AES-GCM box, stored as
  /// nonce + ciphertext + tag.
  Future<Uint8List> _seal(List<int> plain, SecretKey key) async {
    final box = await _aes.encrypt(plain, secretKey: key);
    return Uint8List.fromList(box.concatenation());
  }

  Future<Uint8List> _open(List<int> sealed, SecretKey key) async {
    final box = SecretBox.fromConcatenation(sealed, nonceLength: _nonceLength, macLength: _macLength);
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: key));
  }

  /// File layout: "NWV1" | total plaintext length (8 bytes) | then repeated
  /// [piece length (4 bytes) | nonce | ciphertext | tag]. Each piece is
  /// authenticated together with its position, so pieces can't be reordered,
  /// swapped or dropped without decryption failing.
  Future<void> _encryptFile(File src, File dest, SecretKey key) async {
    final total = await src.length();
    final reader = await src.open();
    final sink = dest.openWrite();
    try {
      sink.add(_magic);
      sink.add((ByteData(8)..setUint64(0, total)).buffer.asUint8List());
      var index = 0;
      var remaining = total;
      while (remaining > 0) {
        final n = remaining < _chunkSize ? remaining : _chunkSize;
        final plain = await reader.read(n);
        if (plain.length != n) throw const FileSystemException('Could not read the whole file');
        final box = await _aes.encrypt(plain, secretKey: key, aad: _aad(index));
        final sealed = box.concatenation();
        sink.add((ByteData(4)..setUint32(0, sealed.length)).buffer.asUint8List());
        sink.add(sealed);
        index++;
        remaining -= n;
      }
      await sink.flush();
    } finally {
      await reader.close();
      await sink.close();
    }
  }

  Future<void> _decryptFile(File src, File dest, SecretKey key) async {
    final reader = await src.open();
    final sink = dest.openWrite();
    try {
      final magic = await reader.read(4);
      if (magic.length != 4 || !_listEquals(magic, _magic)) {
        throw const FormatException('Not a vault file');
      }
      final header = await reader.read(8);
      if (header.length != 8) throw const FormatException('Truncated vault file');
      final total = ByteData.sublistView(Uint8List.fromList(header)).getUint64(0);
      var written = 0;
      var index = 0;
      while (written < total) {
        final lenBytes = await reader.read(4);
        if (lenBytes.length != 4) throw const FormatException('Truncated vault file');
        final len = ByteData.sublistView(Uint8List.fromList(lenBytes)).getUint32(0);
        if (len < _nonceLength + _macLength || len > _chunkSize + _nonceLength + _macLength) {
          throw const FormatException('Corrupt vault file');
        }
        final sealed = await reader.read(len);
        if (sealed.length != len) throw const FormatException('Truncated vault file');
        final box = SecretBox.fromConcatenation(sealed, nonceLength: _nonceLength, macLength: _macLength);
        final plain = await _aes.decrypt(box, secretKey: key, aad: _aad(index));
        sink.add(plain);
        written += plain.length;
        index++;
      }
      if (written != total) throw const FormatException('Vault file length mismatch');
      await sink.flush();
    } finally {
      await reader.close();
      await sink.close();
    }
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- Index ---------------------------------------------------------

  Future<List<VaultItem>> _readIndex(SecretKey key) async {
    final dir = await _vaultDir();
    final file = File(p.join(dir.path, 'index.enc'));
    if (!await file.exists()) return [];
    final json = jsonDecode(utf8.decode(await _open(await file.readAsBytes(), key))) as List<dynamic>;
    return json.map((e) => VaultItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _writeIndex(List<VaultItem> items, SecretKey key) async {
    final dir = await _vaultDir();
    final sealed = await _seal(utf8.encode(jsonEncode(items.map((i) => i.toJson()).toList())), key);
    // Write to a temp name first, then swap in — a crash mid-write can never
    // leave a half-written index behind.
    final tmp = File(p.join(dir.path, 'index.enc.tmp'));
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(p.join(dir.path, 'index.enc'));
  }

  Future<Uint8List?> _makeThumb(File source, bool isVideo) async {
    try {
      if (isVideo) {
        return await VideoCompress.getByteThumbnail(source.path, quality: 50, position: -1);
      }
      return await FlutterImageCompress.compressWithFile(
        source.path,
        minWidth: 320,
        minHeight: 320,
        quality: 60,
      );
    } catch (_) {
      return null; // no thumbnail is fine — the grid shows a placeholder
    }
  }
}
