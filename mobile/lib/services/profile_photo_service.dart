import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/user_avatar.dart';
import 'media_service.dart';

/// Setting and removing MY profile photo.
///
/// The photo file lives in the public Supabase `avatars` bucket at a fixed
/// path per person (avatars/<uid>.jpg) and its address is saved on my public
/// profile (users/<uid>.photoUrl), which is what everyone else reads.
class ProfilePhotoService {
  ProfilePhotoService._();
  static final instance = ProfilePhotoService._();

  String get _uid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  /// Uploads [file] and makes it my profile photo. Returns the new URL.
  ///
  /// A "?v=<time>" is added to the address on purpose: the file path never
  /// changes (each person has exactly one avatar file that is overwritten),
  /// so without it every phone would keep showing the OLD picture from its
  /// image cache after a change.
  Future<String> setPhoto(File file) async {
    final uid = _uid;
    final base = await MediaService.uploadAvatar(file, uid);
    final url = '$base?v=${DateTime.now().millisecondsSinceEpoch}';
    await FirebaseFirestore.instance.collection('users').doc(uid).update({'photoUrl': url});
    AvatarCache.instance.set(uid, url);
    return url;
  }

  /// Removes my profile photo: the profile goes back to showing my initial
  /// for everyone. Deleting the stored file is best-effort — if the storage
  /// bucket doesn't allow deletes the picture simply stops being used (its
  /// address is removed from my profile, so nobody is shown it any more).
  Future<void> removePhoto() async {
    final uid = _uid;
    await FirebaseFirestore.instance.collection('users').doc(uid).update({'photoUrl': null});
    AvatarCache.instance.set(uid, null);
    try {
      await Supabase.instance.client.storage.from('avatars').remove(['avatars/$uid.jpg']);
    } catch (_) {}
  }
}
