import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'app_version.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// If uploads/downloads/deletes here keep failing while text messages work
/// fine, it's almost certainly ONE of these two dashboard settings, not a
/// bug in this file:
///  1. Supabase dashboard -> Edge Functions -> get-signed-url -> Settings
///     -> "Enforce JWT Verification" must be OFF. This function verifies
///     the caller's FIREBASE token itself (see its own file) - Supabase's
///     platform-level JWT gate expects a SUPABASE token instead and will
///     reject a Firebase one before the function code ever runs.
///  2. Supabase dashboard -> Storage -> a bucket literally named "media"
///     (private) must exist.
/// Every exception below now includes the real HTTP status + response body
/// so whichever it is shows up directly in the app's own error snackbar.
class MediaService {
  /// One entry per in-flight (or just-finished/failed) media send, keyed
  /// by that message's clientId. A bubble widget listens to its own
  /// notifier via ValueListenableBuilder to show a live progress ring —
  /// see VoiceMessageBubble / the image/video bubbles in chat_detail_screen
  /// and group_chat_screen, and MessageRelayService.sendMediaMessage /
  /// GroupMessageRelayService.sendGroupMediaMessage, which create and feed
  /// the notifier via [progressReporterFor]. Entries are removed once a
  /// send finally settles (success or failure) — see [clearProgress].
  static final Map<String, ValueNotifier<double>> uploadProgress = {};

  static ValueNotifier<double> progressNotifierFor(String clientId) =>
      uploadProgress.putIfAbsent(clientId, () => ValueNotifier(0.0));

  /// A plain callback bound to [clientId]'s notifier — this is what gets
  /// passed as `onProgress` into [uploadBytes] so the sending code doesn't
  /// need to touch ValueNotifier directly.
  static void Function(double) progressReporterFor(String clientId) =>
      (p) => progressNotifierFor(clientId).value = p;

  static void clearProgress(String clientId) {
    uploadProgress.remove(clientId);
  }

  // BUGFIX: this used to be a HARDCODED literal pointing at one specific
  // project (bgbmrtwbndoewwwjxnxa — the original template project this
  // repo shipped with). Storage/Postgres calls elsewhere in the app go
  // through `Supabase.instance.client`, which is initialized in main.dart
  // from the SUPABASE_URL build-time --dart-define — so as soon as anyone
  // rebuilds this app pointed at THEIR OWN Supabase project (a different
  // URL), every other Supabase call correctly follows them there, but this
  // one function call kept calling the original hardcoded project instead.
  // That project either never had the function deployed, or isn't even
  // this developer's project to deploy to — so no amount of correctly
  // deploying to *your own* project would ever fix the 404, because the
  // app was never calling your project's function in the first place.
  // Deriving this from the same SUPABASE_URL define main.dart uses makes
  // it impossible for the two to drift apart again.
  static String get _edgeFunctionUrl =>
      '${const String.fromEnvironment('SUPABASE_URL')}/functions/v1/get-signed-url';

  static Future<String> _idToken() async {
    return (await FirebaseAuth.instance.currentUser!.getIdToken())!;
  }

  static Never _throwWithDetail(String action, http.Response res) {
    // HTTP 404 with an Edge-Function-shaped body here has one specific,
    // extremely common cause: the `get-signed-url` function exists as
    // SOURCE CODE in this repo but was never actually deployed to the
    // Supabase project (or was deployed under a different project ref).
    // Deploying is a manual step (`supabase functions deploy ...`) that's
    // easy to skip since nothing else in the build fails without it —
    // text messages, auth, everything else keeps working fine. Surface
    // that directly instead of a bare status code, since "404 / requested
    // function was not found" otherwise reads like a generic network
    // hiccup rather than a one-time setup step that got missed.
    if (res.statusCode == 404) {
      throw Exception(
        '$action failed (HTTP 404): the get-signed-url Edge Function is not '
        'deployed on this Supabase project yet. See supabase/SETUP.md for '
        'the deploy steps — this is a one-time setup step, not a bug in the '
        'app itself.',
      );
    }
    throw Exception('$action failed (HTTP ${res.statusCode}): ${res.body}');
  }

  /// Private, signed-URL bucket — used for chat media and stories, where
  /// access should expire and be checked per-request.
  static Future<String> uploadFile(File file, String bucket, String path) async {
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json', ...AppVersion.headers},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'upload'}),
    );
    if (res.statusCode != 200) _throwWithDetail('Failed to get upload URL', res);
    final data = jsonDecode(res.body);

    await Supabase.instance.client.storage
        .from(bucket)
        .uploadToSignedUrl(path, data['token'], file);

    return path;
  }

  /// Same as [uploadFile] but for raw bytes already sitting in memory —
  /// used for encrypted chat media, where we never want the encrypted blob
  /// touching disk on its way out.
  ///
  /// [onProgress], if given, is called with a 0.0-1.0 value as the upload
  /// proceeds. This is a smoothly-creeping ESTIMATE (it caps at 0.9 until
  /// the call actually finishes, then jumps to 1.0), not a true
  /// bytes-sent/bytes-total ratio — the supabase_flutter storage client
  /// doesn't expose a real byte-progress hook for uploadBinaryToSignedUrl,
  /// and reimplementing Supabase Storage's signed-upload wire format by
  /// hand to get one carries a real risk of getting some header or the
  /// exact request shape subtly wrong — which would break uploads outright,
  /// a far worse outcome than a progress bar that's an honest estimate
  /// rather than byte-exact. Good enough to show real, continuous motion
  /// instead of a bar that's either 0% or 100% with nothing in between.
  static Future<String> uploadBytes(
    Uint8List bytes,
    String bucket,
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.05);
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json', ...AppVersion.headers},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'upload'}),
    );
    if (res.statusCode != 200) _throwWithDetail('Failed to get upload URL', res);
    final data = jsonDecode(res.body);
    onProgress?.call(0.15);

    Timer? ticker;
    if (onProgress != null) {
      var estimated = 0.15;
      ticker = Timer.periodic(const Duration(milliseconds: 180), (_) {
        estimated = (estimated + 0.05).clamp(0.0, 0.9);
        onProgress(estimated);
      });
    }
    try {
      await Supabase.instance.client.storage
          .from(bucket)
          .uploadBinaryToSignedUrl(path, data['token'], bytes);
    } finally {
      ticker?.cancel();
    }
    onProgress?.call(1.0);
    return path;
  }

  static Future<String> getDownloadUrl(String bucket, String path) async {
    final idToken = await _idToken();
    final res = await http.post(
      Uri.parse(_edgeFunctionUrl),
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json', ...AppVersion.headers},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'download'}),
    );
    if (res.statusCode != 200) _throwWithDetail('Failed to get download URL', res);
    return jsonDecode(res.body)['signedUrl'];
  }

  static Future<Uint8List> downloadBytes(String bucket, String path) async {
    final signedUrl = await getDownloadUrl(bucket, path);
    final res = await http.get(Uri.parse(signedUrl));
    if (res.statusCode != 200) _throwWithDetail('Failed to download media', res);
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
      headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json', ...AppVersion.headers},
      body: jsonEncode({'bucket': bucket, 'path': path, 'mode': 'delete'}),
    );
    if (res.statusCode != 200) _throwWithDetail('Failed to delete remote media', res);
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
