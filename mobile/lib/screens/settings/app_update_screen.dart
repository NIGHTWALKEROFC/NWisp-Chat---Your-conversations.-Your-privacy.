import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_version.dart';
import '../../services/integrity_service.dart';
import '../../services/update_service.dart';
import '../../widgets/update_ui.dart';

/// Settings → App updates: the version you have, a "Check for updates" button,
/// and what's new in the latest and earlier versions.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  final _svc = UpdateService.instance;
  String? _message;

  Future<void> _check() async {
    final r = await _svc.check();
    if (!mounted) return;
    setState(() {
      switch (r) {
        case UpdateCheckResult.upToDate:
          _message = "You're on the latest version.";
          break;
        case UpdateCheckResult.available:
        case UpdateCheckResult.required:
          _message = null;
          break;
        case UpdateCheckResult.offline:
          _message = "Couldn't reach the update server. Check your connection and try again.";
          break;
        case UpdateCheckResult.notConfigured:
          _message = 'Updates are not set up yet.';
          break;
        case UpdateCheckResult.invalid:
          _message = "The update information couldn't be verified, so it was ignored.";
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('App updates')),
      body: ListenableBuilder(
        listenable: _svc,
        builder: (context, _) {
          final m = _svc.manifest;
          final hasUpdate = _svc.status != UpdateStatus.none && m != null;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
                child: Row(children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: hasUpdate ? scheme.primary : Colors.green.shade600,
                    child: Icon(hasUpdate ? Icons.system_update_alt_rounded : Icons.check_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('NWisp ${AppVersion.name.isEmpty ? '' : 'v${AppVersion.name}'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      Text('Build ${AppVersion.code}', style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(
                        hasUpdate ? 'Version ${m.versionName} is available' : 'Up to date',
                        style: TextStyle(color: hasUpdate ? scheme.primary : Colors.green.shade600, fontWeight: FontWeight.w700),
                      ),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _svc.checking ? null : _check,
                icon: _svc.checking
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh_rounded),
                label: Text(_svc.checking ? 'Checking…' : 'Check for updates'),
              ),
              if (_message != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_message!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant))),
              if (hasUpdate) ...[
                const SizedBox(height: 18),
                UpdateActions(manifest: m),
                for (final mirror in m.mirrors.where((x) => x.url.startsWith('https://')))
                  TextButton(onPressed: () => openUpdateLink(context, mirror.url), child: Text(mirror.label)),
                const SizedBox(height: 12),
                WhatsNewCard(manifest: m),
              ],
              if ((IntegrityService.instance.info?.certs ?? const []).isNotEmpty) ...[
                const SizedBox(height: 18),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.fingerprint),
                  title: const Text('App signature'),
                  subtitle: Text(IntegrityService.instance.info!.certs.first, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  trailing: const Icon(Icons.copy_outlined, size: 20),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: IntegrityService.instance.info!.certs.first));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Signature copied')));
                  },
                ),
              ],
              if (m != null && m.history.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('EARLIER VERSIONS', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.6)),
                const SizedBox(height: 8),
                for (final h in m.history)
                  Card(
                    elevation: 0,
                    color: scheme.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Version ${h.versionName}${h.releaseDate.isNotEmpty ? ' · ${prettyDate(h.releaseDate)}' : ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        for (final n in h.notes) Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('•  $n', style: TextStyle(color: scheme.onSurfaceVariant))),
                      ]),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
