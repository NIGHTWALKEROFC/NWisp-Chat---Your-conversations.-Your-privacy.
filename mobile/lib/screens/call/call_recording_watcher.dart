import 'package:flutter/services.dart';

/// Feature: recording alerts. Asks Android (MainActivity) to tell us when
/// another app starts or stops recording sound while a call is going on.
/// NWisp's own microphone counts as one recording, so "recording" here means
/// "at least one MORE app is recording". Detection is best-effort: it can't
/// see a recording made by a different device or by the phone's own system.
class CallRecordingWatcher {
  CallRecordingWatcher._();

  static const MethodChannel _channel = MethodChannel('com.nightwalker.securechat/call_recording');
  static void Function(bool recording)? _onChange;
  static bool _hooked = false;

  static Future<void> start(void Function(bool recording) onChange) async {
    _onChange = onChange;
    if (!_hooked) {
      _hooked = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'state') _onChange?.call(call.arguments == true);
      });
    }
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    _onChange = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
