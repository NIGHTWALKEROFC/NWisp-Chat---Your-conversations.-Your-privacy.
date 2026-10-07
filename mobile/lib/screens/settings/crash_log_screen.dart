import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/app_version.dart';
import '../../services/crash_report_service.dart';

/// Settings → Crash reports.
///
/// Everything NWisp noticed going wrong on this phone, in one place that YOU
/// control: read it, copy it, share it as a text file, or clear it. Nothing is
/// sent anywhere by the app. Email addresses and long ids are hidden before
/// anything is copied or shared. Send it to the developer only if you want to.
class CrashLogScreen extends StatefulWidget {
  const CrashLogScreen({super.key});

  @override
  State<CrashLogScreen> createState() => _CrashLogScreenState();
}

class _Entry {
  final String kind;
  final String text;
  const _Entry(this.kind, this.text);
}

class _CrashLogScreenState extends State<CrashLogScreen> {
  List<_Entry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final native = await CrashReportService.nativeCrashes();
    final dart = await CrashReportService.recentErrors();
    final list = <_Entry>[
      for (final n in native.reversed) _Entry('Crash', n),
      for (final d in dart.reversed) _Entry('Error', d),
    ];
    if (mounted) setState(() => _entries = list);
  }

  String _report() {
    final b = StringBuffer()
      ..writeln('NWisp crash report')
      ..writeln('App version: ${AppVersion.name} (build ${AppVersion.code})')
      ..writeln('Created: ${DateTime.now().toIso8601String()}')
      ..writeln('Reports: ${_entries?.length ?? 0}')
      ..writeln('---');
    for (final e in _entries ?? const <_Entry>[]) {
      b
        ..writeln('[${e.kind}]')
        ..writeln(CrashReportService.scrub(e.text))
        ..writeln('---');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crash reports'),
        actions: [
          if (list != null && list.isNotEmpty) ...[
            IconButton(
              tooltip: 'Copy all',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _report()));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied')));
              },
            ),
            IconButton(
              tooltip: 'Share as text',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => Share.share(_report(), subject: 'NWisp crash report'),
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear all reports?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                    ],
                  ),
                );
                if (ok == true) {
                  await CrashReportService.clearAll();
                  _load();
                }
              },
            ),
          ],
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_outlined, size: 60, color: Colors.green.shade500),
                        const SizedBox(height: 12),
                        const Text('Nothing went wrong', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                        const SizedBox(height: 6),
                        Text(
                          'If NWisp crashes or hits an error, the details are saved here — only on this phone.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      child: Text(
                        'Only on this phone. Copy or share it if you want to send it to the developer. Email addresses and long ids are hidden automatically.',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                      ),
                    ),
                    for (final e in list)
                      Card(
                        elevation: 0,
                        color: scheme.surfaceContainerHigh,
                        child: ExpansionTile(
                          leading: Icon(e.kind == 'Crash' ? Icons.bug_report_outlined : Icons.error_outline, color: e.kind == 'Crash' ? scheme.error : scheme.tertiary),
                          title: Text(CrashReportService.scrub(e.text.split('\n').firstWhere((l) => l.trim().isNotEmpty && !l.startsWith('time=') && !l.startsWith('thread='), orElse: () => e.kind)), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                          subtitle: Text(e.kind),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                              child: SelectableText(CrashReportService.scrub(e.text), style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }
}
