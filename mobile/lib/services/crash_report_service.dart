import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_strings.dart';
import '../screens/settings/report_problem_screen.dart';

/// Feature: remembers what went wrong, so "Report a problem" can attach it and
/// so the app can offer to report a crash the next time it opens.
///
/// Two separate things are kept, both only on this phone:
///
///  * A short list of the last few errors the app hit while running (Dart
///    errors that were caught by Flutter or escaped unhandled). Most of these
///    are harmless — a failed network request, say — and they do NOT trigger
///    any prompt. They're just attached to a report if the person includes them.
///
///  * A real crash in the Android layer (the app closing by itself). The
///    Android side writes the stack trace to a file just before dying
///    (MainActivity.installCrashRecorder); the next time the app opens, the
///    person is asked once whether to send a report, WhatsApp-style.
///
/// Limits, honestly: a crash deep inside native code, or Android simply
/// killing the app in the background, leaves no trace to report.
///
/// Nothing here is ever sent anywhere by itself. A report only leaves the phone
/// when the person presses send in their own email app.
class CrashReportService {
  CrashReportService._();

  static const _channel = MethodChannel('com.nightwalker.securechat/report');
  static const _kErrors = 'recent_error_log';
  static const _maxErrors = 25;

  /// Hooks the two global error handlers. Call once, first thing in main().
  /// The normal behaviour of each handler is kept — errors still print
  /// the way they always did.
  static void install() {
    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _record(details.exception, details.stack, 'Flutter');
      if (previousFlutterHandler != null) {
        previousFlutterHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error, stack, 'Uncaught');
      return false; // not handled here, so it's still reported as before
    };
  }

  // Writes are queued so two errors at the same moment can't overwrite each other.
  static Future<void> _writeQueue = Future.value();

  static void _record(Object error, StackTrace? stack, String source) {
    _writeQueue = _writeQueue.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final list = prefs.getStringList(_kErrors) ?? <String>[];
        // The message is cut short on purpose: it could contain something
        // typed or received, and a report only needs the kind of error.
        final firstLine = error.toString().split('\n').first;
        final what = '[$source] ${error.runtimeType}: '
            '${firstLine.length > 160 ? '${firstLine.substring(0, 160)}…' : firstLine}';
        if (list.isNotEmpty && list.last.split('\n').first.endsWith(what)) {
          return; // same error as the last one — don't fill the list with repeats
        }
        final summary = '${DateTime.now().toIso8601String()} $what';
        final frames = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).take(14).join('\n');
        list.add(frames.isEmpty ? summary : '$summary\n$frames');
        while (list.length > _maxErrors) {
          list.removeAt(0);
        }
        await prefs.setStringList(_kErrors, list);
      } catch (_) {
        // Recording an error must never cause another one.
      }
    });
  }

  // ---- Feature: crash log you control --------------------------------------
  // Everything stays on this phone. The Crash reports screen (Settings) shows
  // it, and the person decides whether to copy or share it — nothing is
  // uploaded by the app.
  static const _kNativeLog = 'crash_native_log_v1';

  static Future<void> _saveNative(String text) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kNativeLog) ?? <String>[];
      list.add(text);
      while (list.length > 10) {
        list.removeAt(0);
      }
      await prefs.setStringList(_kNativeLog, list);
    } catch (_) {}
  }

  static Future<List<String>> nativeCrashes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_kNativeLog) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kErrors);
      await prefs.remove(_kNativeLog);
    } catch (_) {}
  }

  /// Hides things a report doesn't need: email addresses, long ids and tokens.
  static String scrub(String text) {
    return text
        .replaceAll(RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+'), '[email]')
        .replaceAll(RegExp(r'eyJ[\w-]+\.[\w-]+\.[\w-]+'), '[token]')
        .replaceAll(RegExp(r'\b[A-Za-z0-9]{24,}\b'), '[id]');
  }

  static Future<List<String>> recentErrors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_kErrors) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Returns (and clears) the note the Android side left about its last crash,
  /// or null if there wasn't one.
  static Future<String?> takeNativeCrash() async {
    try {
      return await _channel.invokeMethod<String>('takeNativeCrash');
    } catch (_) {
      return null;
    }
  }

  /// If the app crashed last time, asks whether to send a report. Call a
  /// moment after the app has started. [navigatorKey] is the app's main one.
  static Future<void> promptIfCrashed(GlobalKey<NavigatorState> navigatorKey) async {
    final raw = await takeNativeCrash();
    if (raw == null || raw.trim().isEmpty) return;
    await _saveNative(raw);

    // File format: "time=<ms>\nthread=<name>\n<stack trace>".
    final lines = raw.split('\n');
    final millis = int.tryParse(lines.first.replaceFirst('time=', '').trim());
    if (millis != null) {
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(millis));
      if (age > const Duration(days: 3)) return; // too old to be worth asking about
    }
    final readable = StringBuffer('Crash in the Android layer');
    if (millis != null) readable.write(' at ${DateTime.fromMillisecondsSinceEpoch(millis).toIso8601String()}');
    readable.write('\n${lines.skip(1).join('\n')}');

    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final send = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.bug_report_outlined),
        title: Text(dialogContext.tr('NWisp closed unexpectedly')),
        content: Text(
          dialogContext.tr(
            'It looks like NWisp crashed last time. Want to send a report so it can be fixed? '
            'Your email app opens with the details filled in — you just press send.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(dialogContext.tr('Not now'))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(dialogContext.tr('Send report'))),
        ],
      ),
    );
    if (send != true) return;
    navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => ReportProblemScreen(
          initialSubject: 'NWisp crashed',
          crashDetails: readable.toString(),
        ),
      ),
    );
  }
}
