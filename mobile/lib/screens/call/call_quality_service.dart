import 'package:shared_preferences/shared_preferences.dart';

/// Feature: Settings > Calls > "Low-data mode" and "Recording alerts".
///
/// LOW-DATA MODE squeezes the call's audio (Opus codec) to about 16 kbit/s
/// with silence suppression, which is roughly 0.12 MB a minute instead of
/// 0.25-0.3 MB — handy on a weak or expensive connection. Voices sound a bit
/// thinner. It works by asking for a lower bitrate in the call set-up
/// (SDP) on this phone's side, which also lowers what it sends.
///
/// RECORDING ALERTS: while on a call, NWisp notices when another app on this
/// phone starts recording sound and tells the other person ("may be
/// recording"). It cannot see a recording made by a separate device.
class CallQualityService {
  CallQualityService._();

  static const _kLow = 'call_low_data';
  static const _kRec = 'call_recording_alerts';

  static bool _lowData = false;
  static bool _recordingAlerts = true;
  static bool _loaded = false;

  static bool get lowData => _lowData;
  static bool get recordingAlerts => _recordingAlerts;

  static Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    _lowData = p.getBool(_kLow) ?? false;
    _recordingAlerts = p.getBool(_kRec) ?? true;
    _loaded = true;
  }

  static Future<void> setLowData(bool v) async {
    _lowData = v;
    (await SharedPreferences.getInstance()).setBool(_kLow, v);
  }

  static Future<void> setRecordingAlerts(bool v) async {
    _recordingAlerts = v;
    (await SharedPreferences.getInstance()).setBool(_kRec, v);
  }

  /// Returns [sdp] with the Opus audio limited to [maxBitrate] bit/s when
  /// low-data mode is on; otherwise returns it untouched.
  static String? tune(String? sdp, {int maxBitrate = 16000}) {
    if (!_lowData || sdp == null || sdp.isEmpty) return sdp;
    final nl = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(nl);
    final ptRe = RegExp(r'^a=rtpmap:(\d+) opus/48000');
    String? pt;
    var rtpmapIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      final m = ptRe.firstMatch(lines[i]);
      if (m != null) {
        pt = m.group(1);
        rtpmapIndex = i;
        break;
      }
    }
    if (pt == null) return sdp;
    const wanted = {'stereo': '0', 'useinbandfec': '1', 'usedtx': '1', 'cbr': '0'};
    final prefix = 'a=fmtp:$pt ';
    var fmtpIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith(prefix)) {
        fmtpIndex = i;
        break;
      }
    }
    final params = <String, String>{};
    if (fmtpIndex >= 0) {
      for (final part in lines[fmtpIndex].substring(prefix.length).split(';')) {
        final kv = part.split('=');
        if (kv.first.trim().isEmpty) continue;
        params[kv.first.trim()] = kv.length > 1 ? kv.sublist(1).join('=').trim() : '';
      }
    }
    params.addAll(wanted);
    params['maxaveragebitrate'] = '$maxBitrate';
    params['maxplaybackrate'] = '16000';
    final line = prefix + params.entries.map((e) => e.value.isEmpty ? e.key : '${e.key}=${e.value}').join(';');
    if (fmtpIndex >= 0) {
      lines[fmtpIndex] = line;
    } else {
      lines.insert(rtpmapIndex + 1, line);
    }
    return lines.join(nl);
  }
}
