import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'conversation_service.dart';
import 'crypto_service.dart';
import 'media_compression_service.dart';
import 'media_service.dart';
import 'message_relay_service.dart';
import 'signal_session_service.dart';

/// Feature: Stories — WhatsApp style (device-to-device, nothing kept on a server).
///
/// HOW IT WORKS NOW (this replaces the old Instagram-style version, where every
/// story sat in Firestore + Supabase Storage and every viewer downloaded it from
/// there):
///
///  * POSTING: the photo/video is compressed, encrypted once with a random key,
///    and the encrypted file is dropped in the temporary Supabase "media" bucket.
///    Then ONE small end-to-end-encrypted message (type `story`, carrying the
///    file key) is sent to every person in the audience through the normal
///    message relay — exactly like a chat message.
///  * RECEIVING: each contact's phone picks that message up, downloads the file
///    ONCE, decrypts it and saves it ON THE PHONE. From then on the story lives
///    only on the phones. Nothing is stored in Firestore.
///  * 24 HOURS: every phone deletes its own copy when the story expires. The
///    poster's phone also removes the temporary encrypted file from the server
///    right then (and a server cleanup job is the safety net).
///  * REINSTALL: because the stories were only ever stored on phones, a person
///    who deletes the app and installs it again does NOT get old stories back.
///  * VIEWS / LIKES: tiny encrypted messages (`story_view`, `story_like`) go
///    back to the poster, whose phone keeps the list.
///
/// Server cost per story: one encrypted file (shared by everyone, removed after
/// ~24 h) plus one tiny relay row per contact that is deleted as soon as the
/// contact's phone has picked it up.
class StoryService {
  StoryService._();
  static final instance = StoryService._();

  static const _uuid = Uuid();
  static const _storyHours = 24;

  final _db = FirebaseFirestore.instance;

  String get _uid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  DocumentReference<Map<String, dynamic>> _privateProfileRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('profile');

  // -----------------------------------------------------------------
  // Local storage (JSON index + media files in the app's private folder)
  // -----------------------------------------------------------------

  String? _loadedForUid;
  List<Map<String, dynamic>> _items = [];
  final _changes = StreamController<void>.broadcast();
  Future<void>? _loading;

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'local_stories'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _indexFile(String uid) async => File(p.join((await _dir()).path, 'index_$uid.json'));

  Future<void> _ensureLoaded() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Future.value();
    if (_loadedForUid == uid) return _loading ?? Future.value();
    _loadedForUid = uid;
    _items = [];
    return _loading = () async {
      try {
        final file = await _indexFile(uid);
        if (await file.exists()) {
          final raw = jsonDecode(await file.readAsString()) as List;
          _items = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (e) {
        debugPrint('StoryService: could not read local index: $e');
      }
      await _dropExpiredLocal();
    }();
  }

  Future<void> _save() async {
    final uid = _loadedForUid;
    if (uid == null) return;
    try {
      await (await _indexFile(uid)).writeAsString(jsonEncode(_items), flush: true);
    } catch (e) {
      debugPrint('StoryService: could not save local index: $e');
    }
    _changes.add(null);
  }

  bool _expired(Map<String, dynamic> s) => (s['expiresAt'] as int) <= DateTime.now().millisecondsSinceEpoch;

  Future<void> _dropExpiredLocal() async {
    final gone = _items.where(_expired).toList();
    if (gone.isEmpty) return;
    for (final s in gone) {
      await _deleteFile(s['file'] as String?);
    }
    _items = _items.where((s) => !_expired(s)).toList();
    await _save();
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Plain map the screens use. `createdAt` is a DateTime.
  Map<String, dynamic> _view(Map<String, dynamic> s) => {
        'id': s['id'],
        'uid': s['uid'],
        'mediaType': s['mediaType'],
        'caption': s['caption'] ?? '',
        'file': s['file'],
        'createdAt': DateTime.fromMillisecondsSinceEpoch(s['createdAt'] as int),
        'expiresAt': DateTime.fromMillisecondsSinceEpoch(s['expiresAt'] as int),
        'seen': s['seen'] == true,
        'liked': s['liked'] == true,
        'viewers': Map<String, dynamic>.from((s['viewers'] as Map?) ?? const {}),
        'likes': List<String>.from((s['likes'] as List?) ?? const []),
      };

  /// All stories that are still alive, newest first. Emits again whenever
  /// something changes (a contact's story arrives, a view comes in …).
  Stream<List<Map<String, dynamic>>> feed() async* {
    await _ensureLoaded();
    List<Map<String, dynamic>> snapshot() {
      final live = _items.where((s) => !_expired(s)).toList()
        ..sort((a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int));
      return live.map(_view).toList();
    }

    yield snapshot();
    await for (final _ in _changes.stream) {
      yield snapshot();
    }
  }

  /// Same list as [feed], but only mine.
  Stream<List<Map<String, dynamic>>> myStories() => feed().map((l) => l.where((s) => s['uid'] == _uid).toList());

  /// Reads the story's picture/video bytes from this phone.
  Future<Uint8List> downloadAndDecrypt(Map<String, dynamic> story) async {
    final path = story['file'] as String?;
    if (path == null) throw Exception('Story file missing');
    return Uint8List.fromList(await File(path).readAsBytes());
  }

  Future<bool> haveIViewed(String storyId) async {
    await _ensureLoaded();
    final s = _find(storyId);
    return s == null || s['uid'] == _uid || s['seen'] == true;
  }

  Map<String, dynamic>? _find(String id) {
    for (final s in _items) {
      if (s['id'] == id) return s;
    }
    return null;
  }

  // -----------------------------------------------------------------
  // Contacts + privacy
  // -----------------------------------------------------------------

  /// The people in my Contacts list (the same list the Contacts screen shows).
  Future<List<String>> myContactUids() async {
    final snap = await _db.collection('users').doc(_uid).collection('contacts').get();
    return snap.docs.map((d) => d.id).toList();
  }

  Future<(String, List<String>)> getGlobalPrivacyDefault() async {
    final snap = await _privateProfileRef(_uid).get();
    final data = snap.data();
    final mode = (data?['storyPrivacyMode'] as String?) ?? 'contacts';
    final selected = List<String>.from(data?['storyPrivacySelectedUids'] ?? const []);
    return (mode, selected);
  }

  Future<void> setGlobalPrivacyDefault(String mode, List<String> selectedUids) {
    return _privateProfileRef(_uid).set({
      'storyPrivacyMode': mode,
      'storyPrivacySelectedUids': mode == 'selected' ? selectedUids : <String>[],
    }, SetOptions(merge: true));
  }

  Future<List<String>> _resolveAudience(String mode, List<String> selectedUids) async {
    final audience = <String>{};
    if (mode == 'selected') {
      audience.addAll(selectedUids);
    } else {
      audience.addAll(await myContactUids());
    }
    audience.remove(_uid);
    return audience.toList();
  }

  // -----------------------------------------------------------------
  // Posting
  // -----------------------------------------------------------------

  Future<void> postStory({
    required File mediaFile,
    required String mediaType, // 'image' or 'video'
    String caption = '',
    required String privacyMode,
    List<String> selectedUids = const [],
    void Function(double progress)? onProgress,
  }) async {
    final uid = _uid;
    if (mediaType != 'image' && mediaType != 'video') {
      throw ArgumentError('mediaType must be "image" or "video"');
    }
    await _ensureLoaded();

    onProgress?.call(0.05);
    final Uint8List compressed;
    if (mediaType == 'image') {
      compressed = await MediaCompressionService.compressImage(mediaFile);
    } else {
      final compressedFile = await MediaCompressionService.compressVideo(mediaFile);
      compressed = await compressedFile.readAsBytes();
    }
    onProgress?.call(0.25);

    final audience = await _resolveAudience(privacyMode, selectedUids);

    final storyId = _uuid.v4();
    final now = DateTime.now();
    final expires = now.add(const Duration(hours: _storyHours));

    // 1) My own copy goes on my phone first, so the story shows up at once.
    final dir = await _dir();
    final ext = mediaType == 'video' ? 'mp4' : 'jpg';
    final localPath = p.join(dir.path, '$storyId.$ext');
    await File(localPath).writeAsBytes(compressed, flush: true);
    _items.add({
      'id': storyId,
      'uid': uid,
      'mediaType': mediaType,
      'file': localPath,
      'caption': caption.trim(),
      'createdAt': now.millisecondsSinceEpoch,
      'expiresAt': expires.millisecondsSinceEpoch,
      'seen': true,
      'viewers': <String, int>{},
      'likes': <String>[],
      'audience': audience,
    });
    await _save();

    if (audience.isEmpty) {
      onProgress?.call(1.0);
      return;
    }

    // 2) One encrypted file, shared by everyone, temporarily on the server.
    final fileKey = await CryptoService.generateFileKey();
    final (cipherBytes, nonce) = await CryptoService.encryptFileBytes(compressed, fileKey);
    final remotePath = 'stories/$uid/$storyId.enc';
    try {
      await MediaService.uploadBytes(
        Uint8List.fromList(cipherBytes),
        'media',
        remotePath,
        onProgress: (pr) => onProgress?.call(0.25 + pr * 0.55),
      );
    } catch (e) {
      // Nothing was shared — take the local copy back out so the poster is
      // not left thinking it was sent.
      _items.removeWhere((s) => s['id'] == storyId);
      await _deleteFile(localPath);
      await _save();
      rethrow;
    }
    final idx = _items.indexWhere((s) => s['id'] == storyId);
    if (idx >= 0) _items[idx]['remotePath'] = remotePath;
    await _save();

    // 3) One tiny encrypted note per person.
    final payload = jsonEncode({
      'id': storyId,
      'mediaType': mediaType,
      'fileKey': fileKey,
      'nonce': nonce,
      'caption': caption.trim(),
      'createdAt': now.millisecondsSinceEpoch,
      'expiresAt': expires.millisecondsSinceEpoch,
    });
    var done = 0;
    var delivered = 0;
    for (final peer in audience) {
      try {
        await _sendControl(peer, 'story', payload, mediaPath: remotePath);
        delivered++;
      } catch (e) {
        debugPrint('StoryService: could not send story to $peer: $e');
      }
      done++;
      onProgress?.call(0.8 + 0.2 * done / audience.length);
    }
    if (delivered == 0) {
      throw Exception("Couldn't share your story — check your connection and try again.");
    }
    onProgress?.call(1.0);
  }

  Future<void> _sendControl(String peerUid, String type, String payload, {String? mediaPath}) async {
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(peerUid, payload);
    await insertMessageRelayRow({
      'conversation_id': ConversationService().conversationIdFor(_uid, peerUid),
      'sender_uid': _uid,
      'recipient_uid': peerUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': type,
      'client_id': _uuid.v4(),
      'ttl_hours': _storyHours,
      if (mediaPath != null) 'media_path': mediaPath,
    });
  }

  // -----------------------------------------------------------------
  // Receiving (called from MessageRelayService for the story_* row types)
  // -----------------------------------------------------------------

  /// A contact's story arrived. Downloads it once and keeps it on this phone.
  Future<void> receiveStory({required String ownerUid, required String payload, required String? remotePath}) async {
    await _ensureLoaded();
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final id = data['id'] as String;
    final expiresAt = (data['expiresAt'] as num).toInt();
    if (expiresAt <= DateTime.now().millisecondsSinceEpoch) return; // already over
    if (_find(id) != null) return; // already have it
    if (remotePath == null) throw Exception('Story is missing its file path.');

    final mediaType = data['mediaType'] as String;
    final encrypted = await MediaService.downloadBytes('media', remotePath);
    final plain = await CryptoService.decryptFileBytes(encrypted, data['nonce'] as String, data['fileKey'] as String);

    final dir = await _dir();
    final ext = mediaType == 'video' ? 'mp4' : 'jpg';
    final localPath = p.join(dir.path, '$id.$ext');
    await File(localPath).writeAsBytes(Uint8List.fromList(plain), flush: true);

    _items.add({
      'id': id,
      'uid': ownerUid,
      'mediaType': mediaType,
      'file': localPath,
      'caption': (data['caption'] as String?) ?? '',
      'createdAt': (data['createdAt'] as num).toInt(),
      'expiresAt': expiresAt,
      'seen': false,
      'liked': false,
    });
    await _save();
  }

  Future<void> receiveView({required String viewerUid, required String payload}) async {
    await _ensureLoaded();
    final id = (jsonDecode(payload) as Map<String, dynamic>)['id'] as String;
    final s = _find(id);
    if (s == null || s['uid'] != _uid) return;
    final viewers = Map<String, dynamic>.from((s['viewers'] as Map?) ?? const {});
    viewers.putIfAbsent(viewerUid, () => DateTime.now().millisecondsSinceEpoch);
    s['viewers'] = viewers;
    await _save();
  }

  Future<void> receiveLike({required String viewerUid, required String payload}) async {
    await _ensureLoaded();
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final s = _find(data['id'] as String);
    if (s == null || s['uid'] != _uid) return;
    final likes = List<String>.from((s['likes'] as List?) ?? const []);
    if (data['liked'] == true) {
      if (!likes.contains(viewerUid)) likes.add(viewerUid);
    } else {
      likes.remove(viewerUid);
    }
    s['likes'] = likes;
    await _save();
  }

  Future<void> receiveDelete({required String ownerUid, required String payload}) async {
    await _ensureLoaded();
    final id = (jsonDecode(payload) as Map<String, dynamic>)['id'] as String;
    final s = _find(id);
    if (s == null || s['uid'] != ownerUid) return;
    await _deleteFile(s['file'] as String?);
    _items.removeWhere((e) => e['id'] == id);
    await _save();
  }

  // -----------------------------------------------------------------
  // Views, likes, delete (my actions)
  // -----------------------------------------------------------------

  Future<void> recordView(String storyId, String ownerUid) async {
    await _ensureLoaded();
    if (ownerUid == _uid) return;
    final s = _find(storyId);
    if (s == null) return;
    final firstTime = s['seen'] != true;
    s['seen'] = true;
    await _save();
    if (!firstTime) return;
    try {
      await _sendControl(ownerUid, 'story_view', jsonEncode({'id': storyId}));
    } catch (_) {}
  }

  Future<bool> isLiked(String storyId) async {
    await _ensureLoaded();
    return _find(storyId)?['liked'] == true;
  }

  Future<void> setLiked(String storyId, String ownerUid, bool liked) async {
    await _ensureLoaded();
    final s = _find(storyId);
    if (s == null) return;
    s['liked'] = liked;
    await _save();
    try {
      await _sendControl(ownerUid, 'story_like', jsonEncode({'id': storyId, 'liked': liked}));
    } catch (_) {}
  }

  /// Deletes my own story: here, on every phone that got it, and the server file.
  Future<void> deleteStory(String storyId) async {
    await _ensureLoaded();
    final s = _find(storyId);
    if (s == null) return;
    final audience = List<String>.from((s['audience'] as List?) ?? const []);
    final remotePath = s['remotePath'] as String?;
    await _deleteFile(s['file'] as String?);
    _items.removeWhere((e) => e['id'] == storyId);
    await _save();
    for (final peer in audience) {
      try {
        await _sendControl(peer, 'story_delete', jsonEncode({'id': storyId}));
      } catch (_) {}
    }
    if (remotePath != null) {
      try {
        await MediaService.deleteRemote('media', remotePath);
      } catch (_) {}
    }
  }

  // -----------------------------------------------------------------
  // Cleanup
  // -----------------------------------------------------------------

  /// Called on start-up and every 15 minutes (main.dart). Removes expired
  /// stories from this phone and, for my own, the temporary server file.
  Future<void> purgeMyExpiredStories() async {
    try {
      await _ensureLoaded();
      final gone = _items.where(_expired).toList();
      for (final s in gone) {
        await _deleteFile(s['file'] as String?);
        final remote = s['remotePath'] as String?;
        if (remote != null && s['uid'] == _uid) {
          try {
            await MediaService.deleteRemote('media', remote);
          } catch (_) {}
        }
      }
      if (gone.isNotEmpty) {
        _items = _items.where((s) => !_expired(s)).toList();
        await _save();
      }
    } catch (_) {}
  }

  /// Sign-out / account switch: forget what was loaded for the old account.
  void resetMemory() {
    _loadedForUid = null;
    _items = [];
    _loading = null;
  }
}
