import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'local_media_files.dart';
import 'local_message_store.dart';
import 'nickname_service.dart';
import 'poll_service.dart';

class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

class BackupSummary {
  final int messages;
  final int media;
  const BackupSummary(this.messages, this.media);
}

/// Feature: encrypted backup and restore.
///
/// WHAT IS IN A BACKUP: your chat history (text, reactions, stars, edits,
/// reply links …), the photos/videos/voice messages if you choose to include
/// them, your private nicknames and poll votes.
///
/// WHAT IS NOT: your encryption keys. Those never leave the phone, so after a
/// restore on a new phone your contacts will see a "security code changed"
/// notice (normal — it means a new device) and new messages use fresh keys.
/// Stories are not backed up (they disappear after 24 hours anyway).
///
/// HOW IT IS PROTECTED: the file is encrypted with AES-256-GCM. The key comes
/// from your passphrase through PBKDF2-SHA256 with 300,000 rounds and a random
/// salt. NWisp never sees or stores the passphrase — lose it and the backup
/// cannot be opened by anyone, including us.
///
/// FILE LAYOUT: "NWBK" + version(1) + salt(16) + iterations(4), then a series
/// of records [length(4)][nonce(12)][ciphertext + 16-byte tag]. Each record is
/// encrypted on its own, so big files never have to sit in memory all at once.
class BackupService {
  BackupService._();
  static final instance = BackupService._();

  static const _magic = [0x4E, 0x57, 0x42, 0x4B]; // "NWBK"
  static const _version = 1;
  static const _iterations = 300000;

  static const _tManifest = 1;
  static const _tMessage = 2;
  static const _tMedia = 3;
  static const _tPrefs = 4;
  static const _tEnd = 255;

  final _aes = AesGcm.with256bits();

  static Future<List<int>> _deriveKey(String passphrase, List<int> salt, int iterations) {
    return Isolate.run(() async {
      final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
      final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
      return key.extractBytes();
    });
  }

  Future<List<int>> _sealRecord(SecretKey key, int type, List<int> payload) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt([type, ...payload], secretKey: key, nonce: nonce);
    final body = [...nonce, ...box.cipherText, ...box.mac.bytes];
    final len = ByteData(4)..setUint32(0, body.length);
    return [...len.buffer.asUint8List(), ...body];
  }

  /// Reads the next record, or null at the end of the file.
  Future<(int, Uint8List)?> _readRecord(RandomAccessFile f, SecretKey key) async {
    final lenBytes = await f.read(4);
    if (lenBytes.isEmpty) return null;
    if (lenBytes.length < 4) throw BackupException('The backup file is cut off.');
    final len = ByteData.sublistView(Uint8List.fromList(lenBytes)).getUint32(0);
    if (len < 12 + 16 + 1 || len > 600 * 1024 * 1024) throw BackupException('This is not a valid NWisp backup.');
    final body = await f.read(len);
    if (body.length < len) throw BackupException('The backup file is cut off.');
    final nonce = body.sublist(0, 12);
    final mac = body.sublist(body.length - 16);
    final cipher = body.sublist(12, body.length - 16);
    try {
      final clear = await _aes.decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(mac)), secretKey: key);
      return (clear[0], Uint8List.fromList(clear.sublist(1)));
    } catch (_) {
      throw BackupException('Wrong passphrase, or this file is damaged.');
    }
  }

  // ------------------------------------------------------------------ create

  /// Writes an encrypted backup file and returns it. [onProgress] gets 0–1.
  Future<(File, BackupSummary)> create({
    required String passphrase,
    required bool includeMedia,
    void Function(double progress, String step)? onProgress,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw BackupException('You are signed out.');
    onProgress?.call(0, 'Securing the file…');
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final key = SecretKey(await _deriveKey(passphrase, salt, _iterations));

    final dir = await getTemporaryDirectory();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'nwisp-backup-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}.nwbackup';
    final file = File(p.join(dir.path, name));
    final sink = file.openWrite();
    var messages = 0;
    var media = 0;
    try {
      final iter = ByteData(4)..setUint32(0, _iterations);
      sink.add([..._magic, _version, ...salt, ...iter.buffer.asUint8List()]);

      final all = await LocalMessageStore.exportAllMessages();
      sink.add(await _sealRecord(
        key,
        _tManifest,
        utf8.encode(jsonEncode({'uid': uid, 'createdAt': now.millisecondsSinceEpoch, 'messages': all.length, 'media': includeMedia})),
      ));

      for (var i = 0; i < all.length; i++) {
        final m = all[i];
        String? mediaFileName;
        if (includeMedia && m.mediaPath != null) {
          final f = File(m.mediaPath!);
          if (await f.exists()) {
            mediaFileName = p.basename(m.mediaPath!);
            final idBytes = utf8.encode(m.id);
            final nameBytes = utf8.encode(mediaFileName);
            final head = ByteData(4)
              ..setUint16(0, idBytes.length)
              ..setUint16(2, nameBytes.length);
            sink.add(await _sealRecord(key, _tMedia, [...head.buffer.asUint8List(), ...idBytes, ...nameBytes, ...await f.readAsBytes()]));
            media++;
          }
        }
        sink.add(await _sealRecord(
          key,
          _tMessage,
          utf8.encode(jsonEncode({
            'id': m.id,
            'c': m.conversationId,
            'p': m.peerUid,
            's': m.senderUid,
            'mine': m.isMine,
            't': m.text,
            'type': m.messageType,
            'media': mediaFileName,
            'reply': m.replyToId,
            'react': m.reactions,
            'status': m.status,
            'at': m.createdAt.millisecondsSinceEpoch,
            'exp': m.expiresAt?.millisecondsSinceEpoch,
            'edit': m.editedAt?.millisecondsSinceEpoch,
            'vo': m.isViewOnce,
            'voc': m.viewOnceConsumed,
            'star': m.starred,
            'fwd': m.isForwarded,
          })),
        ));
        messages++;
        if (i % 20 == 0) onProgress?.call(0.1 + 0.85 * (i / (all.length == 0 ? 1 : all.length)), 'Backing up messages…');
      }

      sink.add(await _sealRecord(
        key,
        _tPrefs,
        utf8.encode(jsonEncode({'nick': NicknameService.instance.exportAll(), 'polls': await PollService.instance.exportVotes()})),
      ));
      sink.add(await _sealRecord(key, _tEnd, utf8.encode(jsonEncode({'messages': messages}))));
      await sink.flush();
    } catch (e) {
      await sink.close();
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
    await sink.close();
    onProgress?.call(1, 'Done');
    return (file, BackupSummary(messages, media));
  }

  // ----------------------------------------------------------------- restore

  Future<BackupSummary> restore({
    required File file,
    required String passphrase,
    void Function(double progress, String step)? onProgress,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw BackupException('You are signed out.');
    final f = await file.open();
    try {
      final head = await f.read(4 + 1 + 16 + 4);
      if (head.length < 25 || !_listEq(head.sublist(0, 4), _magic)) throw BackupException('This is not a NWisp backup file.');
      if (head[4] != _version) throw BackupException('This backup was made by a newer version of NWisp. Update the app first.');
      final salt = head.sublist(5, 21);
      final iterations = ByteData.sublistView(Uint8List.fromList(head.sublist(21, 25))).getUint32(0);
      if (iterations < 100000 || iterations > 5000000) throw BackupException('This is not a valid NWisp backup.');
      onProgress?.call(0, 'Checking your passphrase…');
      final key = SecretKey(await _deriveKey(passphrase, salt, iterations));

      final first = await _readRecord(f, key);
      if (first == null || first.$1 != _tManifest) throw BackupException('This is not a valid NWisp backup.');
      final manifest = jsonDecode(utf8.decode(first.$2)) as Map<String, dynamic>;
      if (manifest['uid'] != uid) {
        throw BackupException('This backup belongs to a different NWisp account. Sign in to that account to restore it.');
      }
      final total = (manifest['messages'] as num?)?.toInt() ?? 0;

      final mediaPaths = <String, String>{}; // messageId -> restored file path
      var messages = 0;
      var media = 0;
      var sawEnd = false;
      while (true) {
        final rec = await _readRecord(f, key);
        if (rec == null) break;
        switch (rec.$1) {
          case _tMedia:
            final d = rec.$2;
            final bd = ByteData.sublistView(d);
            final idLen = bd.getUint16(0);
            final nameLen = bd.getUint16(2);
            final id = utf8.decode(d.sublist(4, 4 + idLen));
            final name = utf8.decode(d.sublist(4 + idLen, 4 + idLen + nameLen));
            final bytes = d.sublist(4 + idLen + nameLen);
            final ext = p.extension(name).replaceFirst('.', '');
            mediaPaths[id] = await LocalMediaFiles.save(bytes, ext.isEmpty ? 'bin' : ext);
            media++;
            break;
          case _tMessage:
            final m = jsonDecode(utf8.decode(rec.$2)) as Map<String, dynamic>;
            final id = m['id'] as String;
            final added = await LocalMessageStore.importMessage(
              id: id,
              conversationId: m['c'] as String,
              peerUid: m['p'] as String,
              senderUid: m['s'] as String,
              isMine: m['mine'] == true,
              text: (m['t'] as String?) ?? '',
              messageType: (m['type'] as String?) ?? 'text',
              mediaPath: mediaPaths.remove(id),
              replyToId: m['reply'] as String?,
              reactions: Map<String, String>.from((m['react'] as Map?) ?? const {}),
              status: (m['status'] as String?) ?? 'sent',
              createdAt: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
              expiresAt: m['exp'] == null ? null : DateTime.fromMillisecondsSinceEpoch((m['exp'] as num).toInt()),
              editedAt: m['edit'] == null ? null : DateTime.fromMillisecondsSinceEpoch((m['edit'] as num).toInt()),
              isViewOnce: m['vo'] == true,
              viewOnceConsumed: m['voc'] == true,
              starred: m['star'] == true,
              isForwarded: m['fwd'] == true,
            );
            if (added) messages++;
            if (messages % 25 == 0) onProgress?.call(total == 0 ? 0.5 : 0.1 + 0.85 * (messages / total), 'Restoring messages…');
            break;
          case _tPrefs:
            final d = jsonDecode(utf8.decode(rec.$2)) as Map<String, dynamic>;
            await NicknameService.instance.importAll(Map<String, String>.from((d['nick'] as Map?) ?? const {}));
            await PollService.instance.importVotes(Map<String, dynamic>.from((d['polls'] as Map?) ?? const {}));
            break;
          case _tEnd:
            sawEnd = true;
            break;
        }
      }
      if (!sawEnd) throw BackupException('The backup file is incomplete — it may not have finished copying.');
      LocalMessageStore.notifyAfterRestore();
      onProgress?.call(1, 'Done');
      return BackupSummary(messages, media);
    } finally {
      await f.close();
    }
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
