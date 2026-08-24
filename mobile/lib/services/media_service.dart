import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MediaService {
  static const _edgeFunctionUrl =
      'https://bgbmrtwbndoewwwjxnxa.supabase.co/functions/v1/get-signed-url';

  static Future<String> _idToken() async {
    return (await FirebaseAuth.instance.currentUser!.getIdToken())!;
  }

  /// Private, signed-URL bucket — used for chat media and stories, where
  /// access should expire and be checked per-request.
  static Future<String> uploadFile(File file, String bucket, String path) async {
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'upload'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to get upload URL');
    final data = jsonDecode(res.body);

    await Supabase.instance.client.storage
        .from(bucket)
        .uploadToSignedUrl(path, data['token'], file);

    return path;
  }

  /// Same as [uploadFile] but for raw bytes already sitting in memory —
  /// used for encrypted chat media, where we never want the encrypted blob
  /// touching disk on its way out.
  static Future<String> uploadBytes(Uint8List bytes, String bucket, String path) async {
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'upload'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to get upload URL');
    final data = jsonDecode(res.body);

    await Supabase.instance.client.storage
        .from(bucket)
        .uploadBinaryToSignedUrl(path, data['token'], bytes);

    return path;
  }

  static Future<String> getDownloadUrl(String bucket, String path) async {
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'download'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to get download URL');
    return jsonDecode(res.body)['signedUrl'];
  }

  static Future<Uint8List> downloadBytes(String bucket, String path) async {
    final signedUrl = await getDownloadUrl(bucket, path);
    final res = await http.get(Uri.parse(signedUrl));
    if (res.statusCode != 200) throw Exception('Failed to download media');
    return res.bodyBytes;
  }

  /// Removes the ENCRYPTED blob from Supabase Storage once the recipient's
  /// device has downloaded, decrypted, and saved its own local copy —
  /// this is the "server is just a forwarding tool" half of the media
  /// pipeline. The edge function only allows this for the message's actual
  /// sender or recipient (checked server-side against `message_relay`),
  /// not just anyone who knows the path.
  static Future<void> deleteRemote(String bucket, String path) async {
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'delete'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to delete remote media');
  }

  /// Avatars are shown to everyone a user chats with, so unlike chat media
  /// they use a PUBLIC Supabase bucket instead of a signed URL — otherwise
  /// every viewer would need a fresh signed URL just to see a profile photo.
  ///
  /// One-time setup needed in the Supabase dashboard (not code):
  /// Storage -> New bucket -> name it "avatars" -> toggle "Public bucket" on.
  static Future<String> uploadAvatar(File file, String uid) async {
    final path = 'avatars/$uid.jpg';
    await Supabase.instance.client.storage
        .from('avatars')
        .upload(path, file, fileOptions: const FileOptions(upsert: true));
    return Supabase.instance.client.storage.from('avatars').getPublicUrl(path);
  }

  /// Group avatars use the same public 'avatars' bucket as user avatars —
  /// a group photo isn't secret, every member already sees it the moment
  /// they're a member (same reasoning as [uploadAvatar] above). Filed
  /// under its own 'groups/' prefix so a group id and a uid can never
  /// collide on the same object path.
  static Future<String> uploadGroupAvatar(File file, String groupId) async {
    final path = 'avatars/groups/$groupId.jpg';
    await Supabase.instance.client.storage
        .from('avatars')
        .upload(path, file, fileOptions: const FileOptions(upsert: true));
    return Supabase.instance.client.storage.from('avatars').getPublicUrl(path);
  }
}
