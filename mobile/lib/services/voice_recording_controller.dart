import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// Feature: unified voice/media UI (chat + group). Both
/// chat_detail_screen.dart and group_chat_screen.dart used to each carry
/// their own near-identical copy of this start/cancel/stop-with-timer
/// logic. This is the one shared implementation both now use via
/// composition (each screen's State holds one
/// `VoiceRecordingController` instance) — same tap-to-start/tap-to-stop
/// flow as before (no hold-to-record gesture), same 5-minute auto-stop,
/// same "discard anything under ~1 second" guard against accidental taps.
class VoiceRecordingController {
  final _recorder = AudioRecorder();
  final _uuid = const Uuid();
  Timer? _timer;
  String? _recordingPath;

  static const maxSeconds = 300; // 5 minutes
  static const _minSendableMs = 800; // shorter than this reads as an accidental tap

  bool isRecording = false;
  int seconds = 0;

  /// Called every tick (including right after start/stop, so the caller's
  /// setState always reflects [isRecording]/[seconds] immediately) and
  /// once more automatically at [maxSeconds] via [onMaxLengthReached].
  final void Function() onTick;

  /// Called automatically when a recording hits [maxSeconds] — the caller
  /// should treat this exactly like the user tapping "stop and send".
  final Future<void> Function() onMaxLengthReached;

  VoiceRecordingController({required this.onTick, required this.onMaxLengthReached});

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_uuid.v4()}.m4a');
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    _recordingPath = path;
    isRecording = true;
    seconds = 0;
    onTick();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      seconds++;
      onTick();
      if (seconds >= maxSeconds) onMaxLengthReached();
    });
  }

  /// Stops and discards the recording entirely — the "trash can" button.
  Future<void> cancel() async {
    _timer?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    final path = _recordingPath;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    isRecording = false;
    _recordingPath = null;
    seconds = 0;
    onTick();
  }

  /// Stops recording and returns the finished file + its duration, or
  /// null if the recording was too short to be worth sending (and quietly
  /// deletes it in that case) or if nothing was actually recorded.
  Future<(File, int)?> stopAndFinish() async {
    _timer?.cancel();
    final durationMs = seconds * 1000;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    path ??= _recordingPath;
    isRecording = false;
    _recordingPath = null;
    seconds = 0;
    onTick();

    if (path == null) return null;
    final file = File(path);
    if (durationMs < _minSendableMs) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return null;
    }
    return (file, durationMs);
  }

  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
  }
}
