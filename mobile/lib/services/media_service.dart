import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MediaService {
  static const _edgeFunctionUrl =
      'https://bgbmrtwbndoewwwjxnxa.supabase.co/functions/v1/get-signed-url';

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
}
