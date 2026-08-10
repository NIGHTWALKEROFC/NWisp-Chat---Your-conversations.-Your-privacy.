import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MediaService {
  static const _edgeFunctionUrl =
      'https://bgbmrtwbndoewwwjxnxa.supabase.co/functions/v1/get-signed-url';

  /// Private, signed-URL bucket — used for chat media and stories, where
  /// access should expire and be checked per-request.
  static Future<String> uploadFile(File file, String bucket, String path) async {
    final idToken = await FirebaseAuth.instance.currentUser!.getIdToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'upload'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to get upload URL');
    final data = jsonDecode(res.body);

    await Supabase.instance.client.storage
        .from(bucket)
        .uploadToSignedUrl(path, data['token'], await file.readAsBytes());

    return path;
  }

  static Future<String> getDownloadUrl(String bucket, String path) async {
    final idToken = await FirebaseAuth.instance.currentUser!.getIdToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'download'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to get download URL');
    return jsonDecode(res.body)['signedUrl'];
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
}
