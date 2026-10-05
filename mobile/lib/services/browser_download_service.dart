import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One entry in the Download manager.
class DownloadRecord {
  final String id;
  final String name;
  final String kind;
  final String url;
  final DateTime startedAt;
  String status; // downloading | done | failed | cancelled
  double? progress;
  int? bytes;
  String? savedTo; // a folder path, or "Gallery"
  String? error;

  DownloadRecord({
    required this.id,
    required this.name,
    required this.kind,
    required this.url,
    required this.startedAt,
    this.status = 'downloading',
    this.progress,
    this.bytes,
    this.savedTo,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'url': url,
        't': startedAt.millisecondsSinceEpoch,
        's': status,
        'b': bytes,
        'p': savedTo,
        'e': error,
      };

  static DownloadRecord fromJson(Map<String, dynamic> j) => DownloadRecord(
        id: j['id'] as String,
        name: j['name'] as String,
        kind: (j['kind'] as String?) ?? 'file',
        url: (j['url'] as String?) ?? '',
        startedAt: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
        // A download that was running when the app closed did not finish.
        status: (j['s'] == 'downloading') ? 'failed' : (j['s'] as String),
        bytes: (j['b'] as num?)?.toInt(),
        savedTo: j['p'] as String?,
        error: j['e'] as String?,
      );
}

/// One downloadable file found on the page the person is looking at.
class FoundMedia {
  final String url;
  final String kind; // video | audio | image | file
  final String label; // e.g. "720p", "MP4", "PDF"
  final int? height;
  final String name;
  const FoundMedia({required this.url, required this.kind, required this.label, required this.name, this.height});
}

/// Feature: "Download from this page" in the private browser.
///
/// HONEST LIMITS (also told to the person in the app):
///  * It can only download files the page itself serves as a plain link —
///    video/audio/image tags and direct links such as .mp4 .mp3 .pdf .zip.
///  * It does NOT download from YouTube, Instagram, Netflix and similar sites.
///    Those sites deliver video as protected, split streams, and their terms of
///    service forbid saving it; NWisp does not work around that.
///  * Pages that play video from a `blob:` address can't be downloaded either.
class BrowserDownloadService {
  BrowserDownloadService._();
  static final instance = BrowserDownloadService._();

  // ---- Download manager state -------------------------------------------
  /// Newest first. The Download manager screen listens to this.
  final ValueNotifier<List<DownloadRecord>> records = ValueNotifier(const []);
  bool _recordsLoaded = false;
  final Map<String, bool> _cancelFlags = {};

  Future<void> loadRecords() async {
    if (_recordsLoaded) return;
    _recordsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('download_records_v1');
      if (raw != null) {
        records.value = (jsonDecode(raw) as List).map((e) => DownloadRecord.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keep = records.value.take(100).map((r) => r.toJson()).toList();
      await prefs.setString('download_records_v1', jsonEncode(keep));
    } catch (_) {}
  }

  void _touch() => records.value = List.of(records.value);

  void cancel(String id) => _cancelFlags[id] = true;

  Future<void> remove(String id) async {
    records.value = records.value.where((r) => r.id != id).toList();
    await _persist();
  }

  Future<void> clearFinished() async {
    records.value = records.value.where((r) => r.status == 'downloading').toList();
    await _persist();
  }

  /// JavaScript that lists media on the page. Returns a JSON string.
  static const scanScript = r'''
(function(){
  var out = [], seen = {};
  function add(url, kind, label, height){
    if(!url || url.indexOf('http')!==0 || seen[url]) return; seen[url]=1;
    out.push({url:url, kind:kind, label:label||'', height:height||0});
  }
  function abs(u){ try{ return new URL(u, location.href).href; }catch(e){ return ''; } }
  document.querySelectorAll('video').forEach(function(v){
    var h = v.videoHeight||0;
    if(v.currentSrc) add(abs(v.currentSrc),'video', h? (h+'p'):'Video', h);
    if(v.src) add(abs(v.src),'video', h? (h+'p'):'Video', h);
    v.querySelectorAll('source').forEach(function(s){
      var lab = s.getAttribute('label')||s.getAttribute('res')||s.getAttribute('size')||'';
      if(lab && /^\d+$/.test(lab)) lab = lab+'p';
      add(abs(s.src),'video', lab||'Video', parseInt(lab)||0);
    });
  });
  document.querySelectorAll('audio').forEach(function(a){
    if(a.currentSrc) add(abs(a.currentSrc),'audio','Audio',0);
    if(a.src) add(abs(a.src),'audio','Audio',0);
    a.querySelectorAll('source').forEach(function(s){ add(abs(s.src),'audio','Audio',0); });
  });
  var exts = /\.(mp4|webm|mkv|mov|m4v|mp3|m4a|ogg|wav|flac|pdf|zip|rar|7z|apk|docx?|xlsx?|pptx?|txt|epub)(\?|#|$)/i;
  document.querySelectorAll('a[href]').forEach(function(a){
    var u = abs(a.href);
    var m = u.match(exts); if(!m) return;
    var e = m[1].toLowerCase();
    var kind = /mp4|webm|mkv|mov|m4v/.test(e) ? 'video' : (/mp3|m4a|ogg|wav|flac/.test(e) ? 'audio' : 'file');
    add(u, kind, e.toUpperCase(), 0);
  });
  var big = 0;
  document.querySelectorAll('img').forEach(function(i){
    if(i.naturalWidth>=600 && i.currentSrc && big<6){ big++; add(abs(i.currentSrc),'image', i.naturalWidth+'×'+i.naturalHeight, i.naturalHeight); }
  });
  return JSON.stringify(out);
})();
''';

  static const _blockedHosts = [
    'youtube.com', 'youtu.be', 'googlevideo.com', 'instagram.com', 'cdninstagram.com',
    'netflix.com', 'primevideo.com', 'hotstar.com', 'spotify.com', 'tiktok.com',
  ];

  /// True for sites whose rules forbid saving their media.
  static bool isRestrictedSite(String pageUrl) {
    final host = (Uri.tryParse(pageUrl)?.host ?? '').toLowerCase();
    return _blockedHosts.any((h) => host == h || host.endsWith('.$h'));
  }

  /// Turns the string runJavaScriptReturningResult gave back into a list.
  List<FoundMedia> parse(Object raw) {
    try {
      var text = raw.toString();
      // Android returns the JSON string wrapped in quotes with escapes.
      if (text.startsWith('"') && text.endsWith('"')) {
        text = jsonDecode(text) as String;
      }
      final list = jsonDecode(text) as List;
      final result = <FoundMedia>[];
      for (final e in list) {
        final m = e as Map;
        final url = m['url'] as String;
        if (_blockedHosts.any((h) => (Uri.tryParse(url)?.host ?? '').toLowerCase().endsWith(h))) continue;
        final name = _fileName(url);
        result.add(FoundMedia(
          url: url,
          kind: m['kind'] as String,
          label: (m['label'] as String?) ?? '',
          height: (m['height'] as num?)?.toInt(),
          name: name,
        ));
      }
      result.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
      return result;
    } catch (e) {
      debugPrint('BrowserDownloadService.parse: $e');
      return [];
    }
  }

  String _fileName(String url) {
    final uri = Uri.tryParse(url);
    var name = uri == null || uri.pathSegments.isEmpty ? 'download' : uri.pathSegments.last;
    name = Uri.decodeComponent(name);
    name = name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
    if (name.isEmpty || name.length > 80) name = 'download_${DateTime.now().millisecondsSinceEpoch}';
    if (!name.contains('.')) name = '$name.bin';
    return name;
  }

  /// Size in bytes if the server tells us (HEAD request). Null if unknown.
  Future<int?> sizeOf(String url) async {
    try {
      final res = await http.head(Uri.parse(url), headers: const {'DNT': '1'}).timeout(const Duration(seconds: 8));
      final len = res.headers['content-length'];
      return len == null ? null : int.tryParse(len);
    } catch (_) {
      return null;
    }
  }

  /// Downloads [item]. Videos and pictures go to the gallery; other files go
  /// to the app's Downloads folder and the returned path is where they are.
  /// [onProgress] gets 0.0–1.0 (or null if the size is unknown).
  Future<String> download(FoundMedia item, {void Function(double? progress)? onProgress, bool Function()? cancelled}) async {
    await loadRecords();
    final rec = DownloadRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: item.name,
      kind: item.kind,
      url: item.url,
      startedAt: DateTime.now(),
    );
    records.value = [rec, ...records.value];
    _cancelFlags[rec.id] = false;
    try {
      final where = await _download(
        item,
        onProgress: (v) {
          rec.progress = v;
          _touch();
          onProgress?.call(v);
        },
        cancelled: () => (cancelled?.call() ?? false) || (_cancelFlags[rec.id] ?? false),
        onSize: (b) => rec.bytes = b,
      );
      rec.status = 'done';
      rec.progress = 1;
      rec.savedTo = where.startsWith('/') ? p.dirname(where) : 'Gallery';
      _touch();
      await _persist();
      return where;
    } catch (e) {
      final wasCancelled = (cancelled?.call() ?? false) || (_cancelFlags[rec.id] ?? false);
      rec.status = wasCancelled ? 'cancelled' : 'failed';
      rec.error = e.toString().replaceFirst('Exception: ', '');
      _touch();
      await _persist();
      rethrow;
    } finally {
      _cancelFlags.remove(rec.id);
    }
  }

  Future<String> _download(FoundMedia item, {void Function(double? progress)? onProgress, bool Function()? cancelled, void Function(int bytes)? onSize}) async {
    final tmp = await getTemporaryDirectory();
    final tmpFile = File(p.join(tmp.path, 'nw_dl_${DateTime.now().millisecondsSinceEpoch}_${item.name}'));
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(item.url))..headers['DNT'] = '1';
      final res = await client.send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception('The site refused the download (HTTP ${res.statusCode}).');
      final total = res.contentLength;
      final sink = tmpFile.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        if (cancelled?.call() == true) {
          await sink.close();
          await tmpFile.delete().catchError((_) => tmpFile);
          throw Exception('Cancelled');
        }
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(total != null && total > 0 ? got / total : null);
      }
      await sink.close();
      onSize?.call(got);
    } finally {
      client.close();
    }

    final lower = item.name.toLowerCase();
    try {
      if (item.kind == 'video' && RegExp(r'\.(mp4|mov|m4v|webm|mkv)$').hasMatch(lower)) {
        await Gal.putVideo(tmpFile.path);
        await tmpFile.delete().catchError((_) => tmpFile);
        return 'Saved to your gallery';
      }
      if (item.kind == 'image' && RegExp(r'\.(jpe?g|png|webp|gif)$').hasMatch(lower)) {
        await Gal.putImage(tmpFile.path);
        await tmpFile.delete().catchError((_) => tmpFile);
        return 'Saved to your gallery';
      }
    } catch (_) {
      // fall through to the plain file location below
    }
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'NWisp Downloads'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = File(p.join(dir.path, item.name));
    await tmpFile.copy(dest.path);
    await tmpFile.delete().catchError((_) => tmpFile);
    return dest.path;
  }
}
