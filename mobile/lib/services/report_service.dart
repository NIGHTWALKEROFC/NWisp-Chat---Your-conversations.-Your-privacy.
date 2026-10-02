import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../config/support_config.dart';

enum ReportType { bug, security }

/// Feature: "Report a problem" — gathers the facts that help fix an issue and
/// opens the person's email app with the whole report ready to send.
///
/// Nothing is uploaded: the report only leaves the phone when the person
/// presses send in Gmail (or whichever email app opens). The details collected
/// are the kind any support team asks for — phone model, Android version, app
/// version, battery, storage, network type, screen, language. Never included:
/// messages, contacts, phone number, account details, location or IP address.
class ReportService {
  ReportService._();

  static const _channel = MethodChannel('com.nightwalker.securechat/report');

  /// Facts about the phone and the app, from the Android side (see
  /// MainActivity.collectDeviceDetails). Empty if that isn't available.
  static Future<Map<String, String>> deviceDetails() async {
    try {
      final result = await _channel.invokeMapMethod<String, String>('deviceDetails');
      return result ?? <String, String>{};
    } catch (_) {
      return <String, String>{};
    }
  }

  /// "Label: value" lines, phone facts first, then the app's own settings.
  static String formatDetails(Map<String, String> phone, Map<String, String> appSettings) {
    final lines = <String>[
      for (final e in phone.entries) '${e.key}: ${e.value}',
      for (final e in appSettings.entries) '${e.key}: ${e.value}',
      'Build mode: ${kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug'}',
    ];
    return lines.join('\n');
  }

  static String subjectFor(ReportType type, String subject) {
    final tag = type == ReportType.security ? '[Security]' : '[Bug]';
    return '$tag ${subject.trim()}';
  }

  static String buildBody({
    required ReportType type,
    required String description,
    String? details,
    String? errors,
  }) {
    final buffer = StringBuffer()
      ..writeln(description.trim().isEmpty ? '(no description written)' : description.trim())
      ..writeln()
      ..writeln('Report type: ${type == ReportType.security ? 'Security problem' : 'App bug'}');
    if (details != null && details.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('----- Phone and app details (added automatically) -----')
        ..writeln(details);
    }
    if (errors != null && errors.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('----- Recent error details (added automatically) -----')
        ..writeln(errors.trim());
    }
    return buffer.toString();
  }

  /// Opens Gmail with the report filled in; falls back to any email app.
  /// Returns "gmail", "other", or "none" (no email app at all — in which case
  /// the report text has been copied to the clipboard instead).
  static Future<String> sendByEmail({required String subject, required String body}) async {
    try {
      final result = await _channel.invokeMethod<String>('composeEmail', {
        'to': SupportConfig.reportEmail,
        'subject': subject,
        'body': body,
      });
      if (result == 'gmail' || result == 'other') return result!;
    } catch (_) {
      // fall through to the clipboard
    }
    await Clipboard.setData(ClipboardData(text: 'To: ${SupportConfig.reportEmail}\nSubject: $subject\n\n$body'));
    return 'none';
  }
}
