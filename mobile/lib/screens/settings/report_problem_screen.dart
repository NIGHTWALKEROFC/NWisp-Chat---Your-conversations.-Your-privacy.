import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/support_config.dart';
import '../../l10n/app_strings.dart';
import '../../services/call_privacy_service.dart';
import '../../services/call_service.dart';
import '../../services/crash_report_service.dart';
import '../../services/locale_service.dart';
import '../../services/report_service.dart';
import '../../services/theme_service.dart';

/// Settings > Report a problem — and where the "NWisp crashed, send a report?"
/// prompt leads.
///
/// The person only types a subject and a description. Everything technical
/// (phone, Android, app version, battery, storage, network, recent errors) is
/// collected automatically, shown on request, and put into an email that opens
/// ready to send in Gmail. Nothing is uploaded by the app itself.
class ReportProblemScreen extends StatefulWidget {
  /// Pre-filled when the screen is opened from the crash prompt.
  final String? initialSubject;

  /// The crash's stack trace, when opened from the crash prompt.
  final String? crashDetails;

  const ReportProblemScreen({super.key, this.initialSubject, this.crashDetails});

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _subject = TextEditingController();
  final _description = TextEditingController();

  ReportType _type = ReportType.bug;
  bool _includeDetails = true;
  bool _includeErrors = true;
  bool _sending = false;

  Map<String, String> _phoneDetails = {};
  List<String> _recentErrors = const [];

  bool get _isCrashReport => widget.crashDetails != null;
  bool get _hasErrorInfo => _isCrashReport || _recentErrors.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _subject.text = widget.initialSubject ?? '';
    ReportService.deviceDetails().then((d) {
      if (mounted) setState(() => _phoneDetails = d);
    });
    CrashReportService.recentErrors().then((e) {
      if (mounted) setState(() => _recentErrors = e);
    });
  }

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    super.dispose();
  }

  /// The app's own settings that can matter to a bug (theme, language, ...).
  Map<String, String> _appSettings() {
    final theme = context.read<ThemeService>();
    final language = context.read<LocaleService>().code;
    final media = MediaQuery.of(context);
    return {
      'App language': language ?? 'phone default',
      'App theme': theme.mode.name,
      'App font scale': '${theme.fontScale}',
      'Protect IP in calls': CallPrivacyService.relayOnly
          ? (CallService.isTurnConfigured ? 'on' : 'on (no relay server in this build)')
          : 'off',
      'Window size': '${media.size.width.round()}x${media.size.height.round()} dp, pixel ratio ${media.devicePixelRatio.toStringAsFixed(2)}',
    };
  }

  String _errorText() {
    final parts = <String>[
      if (widget.crashDetails != null) widget.crashDetails!,
      ..._recentErrors,
    ];
    return parts.join('\n\n');
  }

  Future<void> _showIncludedDetails() async {
    final text = ReportService.formatDetails(_phoneDetails, _appSettings());
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.tr('What gets included')),
        content: SingleChildScrollView(
          child: SelectableText(
            text.isEmpty ? dialogContext.tr('Nothing could be read from this phone.') : text,
            style: const TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogContext.tr('Close'))),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final subject = _subject.text.trim();
    final description = _description.text.trim();
    final messenger = ScaffoldMessenger.of(context);

    if (subject.length < 3) {
      messenger.showSnackBar(SnackBar(content: Text(context.tr('Please write a short subject.'))));
      return;
    }
    if (!_isCrashReport && description.length < 10) {
      messenger.showSnackBar(SnackBar(content: Text(context.tr('Please describe the problem in a few words.'))));
      return;
    }

    setState(() => _sending = true);
    final body = ReportService.buildBody(
      type: _type,
      description: description,
      details: _includeDetails ? ReportService.formatDetails(_phoneDetails, _appSettings()) : null,
      errors: _includeErrors && _hasErrorInfo ? _errorText() : null,
    );
    final result = await ReportService.sendByEmail(
      subject: ReportService.subjectFor(_type, subject),
      body: body,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (result == 'none') {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(dialogContext.tr('No email app found')),
          content: Text(
            '${dialogContext.tr('Your report was copied. Paste it into an email to')} ${SupportConfig.reportEmail}.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogContext.tr('OK'))),
          ],
        ),
      );
    } else {
      messenger.showSnackBar(SnackBar(content: Text(context.tr('Your email app opened. Just press send.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final security = _type == ReportType.security;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Report a problem'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            context.tr(
              'Tell us what went wrong. Your email app will open with your message and the technical details '
              'already filled in — you just press send.',
            ),
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 16),
          SegmentedButton<ReportType>(
            segments: [
              ButtonSegment(value: ReportType.bug, icon: const Icon(Icons.bug_report_outlined), label: Text(context.tr('App bug'))),
              ButtonSegment(value: ReportType.security, icon: const Icon(Icons.shield_outlined), label: Text(context.tr('Security problem'))),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          if (security)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 20, color: scheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tr(
                        'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, '
                        'so describe the problem without the secret itself.',
                      ),
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _subject,
            maxLength: 100,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: context.tr('Subject')),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _description,
            minLines: 6,
            maxLines: 12,
            maxLength: 3000,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              labelText: security ? context.tr('Describe the security problem') : context.tr('What happened?'),
              hintText: security
                  ? context.tr('What could someone do, and how? Steps to reproduce it help a lot.')
                  : context.tr('What did you do, what did you expect, and what happened instead?'),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(context.tr('Include phone and app details')),
            subtitle: Text(
              context.tr(
                'Phone model, Android and app version, battery, storage, network type and similar. '
                'Never your messages, contacts, phone number, account details, location or IP address.',
              ),
            ),
            value: _includeDetails,
            onChanged: (v) => setState(() => _includeDetails = v),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _showIncludedDetails,
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: Text(context.tr('See exactly what is included')),
            ),
          ),
          if (_hasErrorInfo)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(_isCrashReport ? context.tr('Include the crash details') : context.tr('Include recent error details')),
              subtitle: Text(context.tr('Technical error information from this app, which helps find the cause.')),
              value: _includeErrors,
              onChanged: (v) => setState(() => _includeErrors = v),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2))
                : const Icon(Icons.send_rounded),
            label: Text(context.tr('Send report')),
          ),
          const SizedBox(height: 10),
          Text(
            '${context.tr('Goes to')} ${SupportConfig.reportEmail}',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
