import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'crypto_service.dart';
import 'media_compression_service.dart';
import 'media_service.dart';

/// Feature: Stories — 24-hour auto-expiring photo/video posts, with
/// viewers, likes, and a privacy audience (either "all my contacts" or a
/// specific hand-picked list), settable both as an app-wide default and
/// per-story.
///
/// PIPELINE for posting: pick media -> compress it (MediaCompressionService,
/// the same one chat media already uses) -> generate a random one-time AES
/// key (CryptoService.generateFileKey) -> encrypt the compressed bytes with
/// it -> upload the ciphertext to Supabase Storage at
/// `stories/<myUid>/<storyId>.enc` -> create the Firestore document at
/// `stories/<storyId>` carrying the encryption key, the audience list, and
/// when it expires.
///
/// DELIBERATE DESIGN TRADE-OFF, worth understanding before relying on this:
/// unlike 1:1 and group chat messages (which use Signal Protocol sessions —
/// see SignalSessionService — so not even this app's own servers ever see
/// the key), a story's file key is stored directly ON the Firestore
/// document. Firestore's security rules are what gate who can read that
/// document (only uids in `audienceUids` — see firestore.rules' `stories`
/// match block), and Supabase Storage never receives anything but the
/// encrypted bytes — so the media is genuinely encrypted at rest and not
/// downloadable by an outsider. But it is NOT end-to-end encrypted the way
/// chat messages are: Firebase, as the host of Firestore, could in
/// principle read a story's key. Doing this the fully end-to-end way would
/// mean fanning the key out to every audience member individually through
/// their existing Signal session with you (the way group chat messages
/// fan out) at post time — a real, buildable enhancement, just a
/// meaningfully bigger one, and left for a future pass rather than folded
/// in here silently.
///
/// AUTO-EXPIRY is a Firestore TTL policy on the `expiresAt` field
/// (configured once in the Firebase Console, not in this code) — Firestore
/// deletes the document itself automatically, usually within 24 hours of
/// that timestamp passing. That only ever removes the METADATA document,
/// though; the encrypted file sitting in Supabase Storage is a separate
/// thing TTL knows nothing about, which is what [purgeMyExpiredStories]
/// below is for.
class StoryService {
  StoryService._();
  static final instance = StoryService._();

  final _db = FirebaseFirestore.instance;
  String get _uid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  CollectionReference<Map<String, dynamic>> get _stories => _db.collection('stories');

  DocumentReference<Map<String, dynamic>> _privateProfileRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('profile');

  // -----------------------------------------------------------------
  // Contacts (the "all my contacts" audience option resolves to this)
  // -----------------------------------------------------------------

  /// "Contacts" for story-privacy purposes means the same thing the
  /// Contacts tab already means in this app: people you have an existing
  /// 1:1 conversation with (see ContactsScreen) — there's no separate
  /// phone-address-book concept here. Group conversation ids always start
  /// with "group_" (see MessageRelayService/TrafficCamouflageService's own
  /// constant for this) and are excluded, same as those two.
  Future<List<String>> myContactUids() async {
    final uid = _uid;
    final snap = await _db.collection('conversations').where('participants', arrayContains: uid).get();
    final result = <String>{};
    for (final doc in snap.docs) {
      if (doc.id.startsWith('group_')) continue;
      final participants = List<String>.from(doc.data()['participants'] ?? const []);
      final peer = participants.firstWhere((p) => p != uid, orElse: () => '');
      if (peer.isNotEmpty) result.add(peer);
    }
    return result.toList();
  }

  // -----------------------------------------------------------------
  // Privacy — an app-wide default, overridable per story at post time.
  // -----------------------------------------------------------------

  /// Returns (mode, selectedUids). mode is 'contacts' (the default if
  /// nothing has ever been set) or 'selected'; selectedUids is only
  /// meaningful when mode is 'selected'.
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

  /// Turns a privacy choice into the actual list of uids a new story
  /// should be visible to. Always includes the poster themself, so their
  /// own story shows up in their own feed query the same way everyone
  /// else's does.
  Future<List<String>> _resolveAudience(String mode, List<String> selectedUids) async {
    final uid = _uid;
    final audience = <String>{uid};
    if (mode == 'selected') {
      audience.addAll(selectedUids);
    } else {
      audience.addAll(await myContactUids());
    }
    return audience.toList();
  }

  // -----------------------------------------------------------------
  // Posting
  // -----------------------------------------------------------------

  /// [privacyMode]/[selectedUids] are what THIS story is posted with —
  /// pass the app-wide default (see [getGlobalPrivacyDefault]) unless the
  /// person explicitly overrode it for this one post in the composer.
  /// The resolved audience is a SNAPSHOT taken right now: a contact added
  /// after this story is posted won't retroactively see it, and someone
  /// removed as a contact afterwards still can until it expires — the
  /// same "who could see it at the moment it was shared" behavior most
  /// story-style features use.
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

    onProgress?.call(0.05);
    final Uint8List compressed;
    if (mediaType == 'image') {
      compressed = await MediaCompressionService.compressImage(mediaFile);
    } else {
      final compressedFile = await MediaCompressionService.compressVideo(mediaFile);
      compressed = await compressedFile.readAsBytes();
    }
    onProgress?.call(0.25);

    final fileKey = await CryptoService.generateFileKey();
    final (cipherBytes, nonce) = await CryptoService.encryptFileBytes(compressed, fileKey);
    onProgress?.call(0.35);

    final docRef = _stories.doc(); // grab the id up front so the storage path can use it
    final storyId = docRef.id;
    final mediaPath = 'stories/$uid/$storyId.enc';

    await MediaService.uploadBytes(
      Uint8List.fromList(cipherBytes),
      'media',
      mediaPath,
      onProgress: (p) => onProgress?.call(0.35 + p * 0.55),
    );

    final audienceUids = await _resolveAudience(privacyMode, selectedUids);
    final now = DateTime.now();

    await docRef.set({
      'uid': uid,
      'mediaPath': mediaPath,
      'mediaType': mediaType,
      'fileKey': fileKey,
      'nonce': nonce,
      'caption': caption.trim(),
      'audienceUids': audienceUids,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
    });
    onProgress?.call(1.0);
  }

  // -----------------------------------------------------------------
  // Feed / reading
  // -----------------------------------------------------------------

  /// Every not-yet-expired story visible to me, across everyone —
  /// screens group these by `uid` themselves for the "story rings" list
  /// (kept here as a flat stream so the service stays a thin Firestore
  /// wrapper, same style as ConversationService elsewhere in this app).
  Stream<QuerySnapshot<Map<String, dynamic>>> feedStories() {
    final uid = _uid;
    return _stories
        .where('audienceUids', arrayContains: uid)
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .orderBy('expiresAt')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> myStories() {
    return _stories
        .where('uid', isEqualTo: _uid)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  /// Downloads and decrypts one story's media. Call this when the person
  /// actually opens a story to view it, not ahead of time — nothing here
  /// is cached, so re-viewing the same story downloads it again.
  Future<Uint8List> downloadAndDecrypt(Map<String, dynamic> storyData) async {
    final mediaPath = storyData['mediaPath'] as String;
    final fileKey = storyData['fileKey'] as String;
    final nonce = storyData['nonce'] as String;
    final cipherBytes = await MediaService.downloadBytes('media', mediaPath);
    final plain = await CryptoService.decryptFileBytes(cipherBytes, nonce, fileKey);
    return Uint8List.fromList(plain);
  }

  // -----------------------------------------------------------------
  // Views
  // -----------------------------------------------------------------

  /// Records that I viewed [storyId]. A no-op for your own stories —
  /// call sites should still feel free to call this unconditionally
  /// rather than remembering to check first, since posting a "view" of
  /// your own story would be meaningless either way.
  Future<void> recordView(String storyId, String ownerUid) async {
    final uid = _uid;
    if (uid == ownerUid) return;
    await _stories.doc(storyId).collection('views').doc(uid).set({
      'viewedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Owner-only (see firestore.rules) — who has viewed one of MY stories,
  /// most recent first.
  Stream<QuerySnapshot<Map<String, dynamic>>> viewersStream(String storyId) {
    return _stories.doc(storyId).collection('views').orderBy('viewedAt', descending: true).snapshots();
  }

  /// Whether I have already viewed [storyId] — used to color a contact's
  /// story ring as "new" vs "already seen" on the Stories tab. Anyone can
  /// check their OWN view record this way (see firestore.rules); only the
  /// story's owner can read anyone else's.
  Future<bool> haveIViewed(String storyId) async {
    final doc = await _stories.doc(storyId).collection('views').doc(_uid).get();
    return doc.exists;
  }

  // -----------------------------------------------------------------
  // Likes
  // -----------------------------------------------------------------

  Future<void> setLiked(String storyId, bool liked) async {
    final ref = _stories.doc(storyId).collection('likes').doc(_uid);
    if (liked) {
      await ref.set({'likedAt': FieldValue.serverTimestamp()});
    } else {
      await ref.delete();
    }
  }

  Stream<bool> myLikeStream(String storyId) {
    return _stories.doc(storyId).collection('likes').doc(_uid).snapshots().map((s) => s.exists);
  }

  /// Owner-only (see firestore.rules) — everyone who liked one of MY
  /// stories. Streamed in full rather than just a count, since the owner
  /// is also allowed to see WHO liked it (see StoryViewersScreen), and
  /// this list is bounded by the story's own audience size.
  Stream<QuerySnapshot<Map<String, dynamic>>> likesStream(String storyId) {
    return _stories.doc(storyId).collection('likes').snapshots();
  }

  // -----------------------------------------------------------------
  // Deleting / expiry cleanup
  // -----------------------------------------------------------------

  /// Manual "delete my story" — removes the Firestore document right
  /// away and best-effort removes the Storage file too (see
  /// [purgeMyExpiredStories]'s comment on why that part is best-effort).
  Future<void> deleteStory(String storyId, String mediaPath) async {
    await _stories.doc(storyId).delete();
    try {
      await MediaService.deleteRemote('media', mediaPath);
    } catch (_) {
      // The Firestore doc is already gone either way, which is what
      // actually matters for privacy/visibility; a Storage delete that
      // fails here just means an orphaned encrypted file that can no
      // longer be linked to anyone since its metadata is gone.
    }
  }

  /// Best-effort cleanup for MY OWN stories whose `expiresAt` has already
  /// passed: deletes the Firestore doc immediately (rather than waiting
  /// for Firestore's TTL sweep, which can take up to ~24h after
  /// expiresAt) and removes the Storage file with it. Called periodically
  /// while this device is signed in and running (see main.dart's existing
  /// sweep timer) — same honest limitation as Firestore TTL itself: if
  /// this device never runs again after a story expires, the Storage file
  /// is only ever cleaned up by the TTL policy deleting the Firestore doc
  /// (which happens regardless), leaving that one encrypted file orphaned
  /// in Storage. A small, bounded amount of leftover storage in that edge
  /// case, not a privacy issue (nobody can read it without the key.).
  Future<void> purgeMyExpiredStories() async {
    try {
      final uid = _uid;
      final snap = await _stories
          .where('uid', isEqualTo: uid)
          .where('expiresAt', isLessThanOrEqualTo: Timestamp.now())
          .get();
      for (final doc in snap.docs) {
        final mediaPath = doc.data()['mediaPath'] as String?;
        await doc.reference.delete();
        if (mediaPath != null) {
          try {
            await MediaService.deleteRemote('media', mediaPath);
          } catch (_) {
            // Best-effort, as above.
          }
        }
      }
    } catch (_) {
      // Never let a background cleanup sweep surface an error to the
      // person — same posture as LocalMessageStore.purgeExpired().
    }
  }
}
