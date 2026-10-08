import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/integrity_service.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

String prettyDate(String iso) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null || m < 1 || m > 12) return iso;
  return '$d ${months[m - 1]} $y';
}

/// Opens an update link in the phone's own browser / download manager.
Future<void> openUpdateLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return;
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && context.mounted) {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open the link — it was copied. Paste it in your browser.")));
    }
  }
}

// ---------------------------------------------------------------------------
// The big glowing "Update now" button
// ---------------------------------------------------------------------------

class GlowUpdateButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const GlowUpdateButton({super.key, required this.onTap, this.label = 'Update now'});

  @override
  State<GlowUpdateButton> createState() => _GlowUpdateButtonState();
}

class _GlowUpdateButtonState extends State<GlowUpdateButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final glow = 0.25 + 0.35 * _c.value;
        return Container(
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(colors: [Color(0xFF7C4DFF), Color(0xFF2979FF), Color(0xFF00E5FF)], begin: Alignment.centerLeft, end: Alignment.centerRight),
            boxShadow: [BoxShadow(color: const Color(0xFF2979FF).withValues(alpha: glow), blurRadius: 22 + 10 * _c.value, spreadRadius: 1)],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () {
                HapticFeedback.mediumImpact();
                widget.onTap();
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Transform.translate(offset: Offset(0, 2 * _c.value), child: const Icon(Icons.download_rounded, color: Colors.white, size: 26)),
                  const SizedBox(width: 10),
                  Text(widget.label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// The update button area: button -> progress -> checking -> install
// ---------------------------------------------------------------------------

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(bytes >= 100 * 1024 * 1024 ? 0 : 1);

class UpdateActions extends StatefulWidget {
  final UpdateManifest manifest;
  final bool dark;
  const UpdateActions({super.key, required this.manifest, this.dark = false});

  @override
  State<UpdateActions> createState() => _UpdateActionsState();
}

class _UpdateActionsState extends State<UpdateActions> {
  late final Future<bool> _inApp = UpdateInstaller.instance.canDownloadInApp(widget.manifest);

  @override
  Widget build(BuildContext context) {
    final inst = UpdateInstaller.instance;
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.dark ? Colors.white : scheme.onSurface;
    final sub = widget.dark ? Colors.white70 : scheme.onSurfaceVariant;
    final m = widget.manifest;

    Widget card(List<Widget> children) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.dark ? Colors.white.withValues(alpha: 0.10) : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: widget.dark ? Colors.white24 : scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        );

    return FutureBuilder<bool>(
      future: _inApp,
      builder: (context, snap) {
        final inApp = snap.data ?? false;
        return ListenableBuilder(
          listenable: inst,
          builder: (context, _) {
            switch (inst.phase) {
              case InstallPhase.downloading:
                final pct = inst.progress == null ? '' : '  ·  ${(inst.progress! * 100).toStringAsFixed(0)}%';
                return card([
                  Row(children: [
                    Icon(Icons.downloading_rounded, color: fg),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Downloading update…', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 16))),
                  ]),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      minHeight: 10,
                      value: inst.progress,
                      backgroundColor: fg.withValues(alpha: 0.15),
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF40C4FF)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    inst.totalBytes > 0 ? '${_mb(inst.receivedBytes)} of ${_mb(inst.totalBytes)} MB$pct' : '${_mb(inst.receivedBytes)} MB',
                    style: TextStyle(color: sub, fontSize: 13),
                  ),
                  TextButton(onPressed: inst.cancel, child: Text('Cancel', style: TextStyle(color: sub))),
                ]);
              case InstallPhase.verifying:
                return card([
                  Row(children: [
                    SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: fg)),
                    const SizedBox(width: 14),
                    Expanded(child: Text('Checking the file is genuine…', style: TextStyle(color: fg, fontWeight: FontWeight.w700))),
                  ]),
                ]);
              case InstallPhase.needPermission:
                return card([
                  Text('One quick permission', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 6),
                  Text(
                    'Android needs your OK before NWisp can open the installer. Turn on "Allow from this source", then come back — the update continues by itself.',
                    style: TextStyle(color: sub, height: 1.35, fontSize: 13.5),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: inst.openInstallPermissionSettings, child: const Text('Open the setting')),
                ]);
              case InstallPhase.ready:
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  GlowUpdateButton(label: 'Install now', onTap: inst.install),
                  const SizedBox(height: 8),
                  Text(
                    "The file is checked and ready. If the installer didn't open, tap Install now. After installing, open NWisp again.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: sub, fontSize: 12.5),
                  ),
                ]);
              case InstallPhase.error:
                return card([
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline_rounded, color: Color(0xFFFF8A80)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(inst.error, style: TextStyle(color: fg, height: 1.35, fontSize: 13.5))),
                  ]),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () => inst.start(m), child: const Text('Try again')),
                  if (inst.offerBrowserFallback)
                    TextButton(onPressed: () => openUpdateLink(context, m.downloadUrl), child: const Text('Download in browser instead')),
                ]);
              case InstallPhase.idle:
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  GlowUpdateButton(
                    onTap: inApp ? () => inst.start(m) : () => openUpdateLink(context, m.downloadUrl),
                  ),
                  if (inApp)
                    TextButton(
                      onPressed: () => openUpdateLink(context, m.downloadUrl),
                      child: Text('Download in browser instead', style: TextStyle(color: sub, fontSize: 12.5)),
                    ),
                ]);
            }
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Remote notice banner (from update.json "notices")
// ---------------------------------------------------------------------------

class NoticeBanner extends StatelessWidget {
  final AppNotice notice;
  final double topInset;
  const NoticeBanner({super.key, required this.notice, required this.topInset});

  @override
  Widget build(BuildContext context) {
    final ml = Localizations.localeOf(context).languageCode == 'ml' && notice.textMl.isNotEmpty;
    final text = ml ? notice.textMl : notice.text;
    final Color bg;
    final Color fg;
    final IconData icon;
    switch (notice.level) {
      case 'critical':
        bg = const Color(0xFFC62828);
        fg = Colors.white;
        icon = Icons.error_outline_rounded;
        break;
      case 'warning':
        bg = const Color(0xFFFFB300);
        fg = const Color(0xFF2B1B00);
        icon = Icons.warning_amber_rounded;
        break;
      default:
        bg = const Color(0xFF1565C0);
        fg = Colors.white;
        icon = Icons.info_outline_rounded;
    }
    return Material(
      color: bg,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, topInset + 8, 6, 8),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 13.5, height: 1.3, fontWeight: FontWeight.w600)),
                  if (notice.linkUrl.startsWith('https://'))
                    GestureDetector(
                      onTap: () => openUpdateLink(context, notice.linkUrl),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(notice.linkLabel, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w800, decoration: TextDecoration.underline)),
                      ),
                    ),
                ],
              ),
            ),
            if (notice.dismissible)
              IconButton(
                icon: Icon(Icons.close_rounded, color: fg, size: 20),
                tooltip: 'Dismiss',
                onPressed: () => UpdateService.instance.dismissNotice(notice.id),
              )
            else
              const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// "What's new" block
// ---------------------------------------------------------------------------

class WhatsNewCard extends StatelessWidget {
  final UpdateManifest manifest;
  final bool dark; // drawn on the dark gradient page
  const WhatsNewCard({super.key, required this.manifest, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = dark ? Colors.white : scheme.onSurface;
    final sub = dark ? Colors.white70 : scheme.onSurfaceVariant;
    Widget section(IconData icon, String title, List<String> items, Color accent) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 14.5)),
            ]),
            const SizedBox(height: 6),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(left: 26, bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: TextStyle(color: sub)),
                    Expanded(child: Text(item, style: TextStyle(color: sub, height: 1.35, fontSize: 13.5))),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    // Malayalam notes for people who use the app in Malayalam (when provided).
    final ml = Localizations.localeOf(context).languageCode == 'ml';
    final whatsNew = ml && manifest.whatsNewMl.isNotEmpty ? manifest.whatsNewMl : manifest.whatsNew;
    final improved = ml && manifest.improvedMl.isNotEmpty ? manifest.improvedMl : manifest.improved;
    final fixed = ml && manifest.fixedMl.isNotEmpty ? manifest.fixedMl : manifest.fixed;
    final empty = whatsNew.isEmpty && improved.isEmpty && fixed.isEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.10) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: dark ? Colors.white24 : scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ml ? 'പുതിയ വിശേഷങ്ങൾ' : "What's new", style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 12),
          if (empty) Padding(padding: const EdgeInsets.only(bottom: 14), child: Text('Improvements and fixes.', style: TextStyle(color: sub))),
          section(Icons.auto_awesome_rounded, ml ? 'പുതിയത്' : 'New', whatsNew, const Color(0xFFFFD54F)),
          section(Icons.trending_up_rounded, ml ? 'മെച്ചപ്പെടുത്തിയത്' : 'Improved', improved, const Color(0xFF69F0AE)),
          section(Icons.build_circle_outlined, ml ? 'പരിഹരിച്ചത്' : 'Fixed', fixed, const Color(0xFF80D8FF)),
        ],
      ),
    );
  }
}

class _VersionChips extends StatelessWidget {
  final UpdateManifest m;
  const _VersionChips({required this.m});

  @override
  Widget build(BuildContext context) {
    Widget chip(IconData i, String t) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(i, size: 15, color: Colors.white70),
            const SizedBox(width: 6),
            Text(t, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        );
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(Icons.new_releases_outlined, 'Version ${m.versionName}'),
        if (m.releaseDate.isNotEmpty) chip(Icons.event_outlined, prettyDate(m.releaseDate)),
        if (m.sizeMb != null) chip(Icons.sd_storage_outlined, '${m.sizeMb!.toStringAsFixed(m.sizeMb! % 1 == 0 ? 0 : 1)} MB'),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Full-screen "update required"
// ---------------------------------------------------------------------------

class UpdateRequiredView extends StatelessWidget {
  final UpdateManifest manifest;
  const UpdateRequiredView({super.key, required this.manifest});

  @override
  Widget build(BuildContext context) {
    final svc = UpdateService.instance;
    return PopScope(
      canPop: false,
      child: Material(
        color: const Color(0xFF0B1020),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF1B1464), Color(0xFF0B1020), Color(0xFF05243A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 12),
                    children: [
                      Center(
                        child: Container(
                          width: 104,
                          height: 104,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(colors: [Color(0xFF7C4DFF), Color(0xFF00B0FF)]),
                            boxShadow: [BoxShadow(color: const Color(0xFF7C4DFF).withValues(alpha: 0.55), blurRadius: 40, spreadRadius: 4)],
                          ),
                          child: const Icon(Icons.system_update_alt_rounded, color: Colors.white, size: 52),
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Text('Update required', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      Text(
                        (Localizations.localeOf(context).languageCode == 'ml' && manifest.messageMl.isNotEmpty)
                            ? manifest.messageMl
                            : manifest.message.isNotEmpty ? manifest.message : 'This version of NWisp is no longer supported. Update to keep chatting securely.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, height: 1.4, fontSize: 14.5),
                      ),
                      const SizedBox(height: 16),
                      _VersionChips(m: manifest),
                      const SizedBox(height: 22),
                      WhatsNewCard(manifest: manifest, dark: true),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 6, 22, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UpdateActions(manifest: manifest, dark: true),
                      const SizedBox(height: 6),
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          for (final mirror in manifest.mirrors.where((m) => m.url.startsWith('https://')))
                            TextButton(
                              onPressed: () => openUpdateLink(context, mirror.url),
                              child: Text(mirror.label, style: const TextStyle(color: Colors.white70)),
                            ),
                          TextButton(
                            onPressed: () => svc.check(),
                            child: const Text('I already updated — check again', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
                          ),
                        ],
                      ),
                      const Text(
                        'Download the file, open it, and tap Install. Your chats stay on your phone.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// "Modified copy" notice
// ---------------------------------------------------------------------------

class TamperView extends StatefulWidget {
  const TamperView({super.key});

  @override
  State<TamperView> createState() => _TamperViewState();
}

class _TamperViewState extends State<TamperView> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(const Duration(seconds: 6), () => IntegrityService.instance.closeApp());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Material(
        color: const Color(0xFF1A0B0B),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.gpp_bad_outlined, color: Color(0xFFFF5252), size: 78),
                const SizedBox(height: 20),
                const Text('This copy has been modified', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                const Text(
                  "This version of NWisp isn't the original, so it can't be trusted with your messages. NWisp will close now. Please download the official app from the developer.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Optional update: a friendly sheet that can be dismissed
// ---------------------------------------------------------------------------

Future<void> showUpdateAvailableSheet(BuildContext context, UpdateManifest m) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              children: [
                Row(children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: const LinearGradient(colors: [Color(0xFF7C4DFF), Color(0xFF00B0FF)])),
                    child: const Icon(Icons.system_update_alt_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('A new version is ready', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                      Text(
                        'Version ${m.versionName}${m.releaseDate.isNotEmpty ? ' · ${prettyDate(m.releaseDate)}' : ''}${m.sizeMb != null ? ' · ${m.sizeMb!.toStringAsFixed(0)} MB' : ''}',
                        style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                    ]),
                  ),
                ]),
                if (m.message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(m.message)),
                const SizedBox(height: 16),
                WhatsNewCard(manifest: m),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                UpdateActions(manifest: m),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (final mirror in m.mirrors.where((x) => x.url.startsWith('https://')))
                    TextButton(onPressed: () => openUpdateLink(ctx, mirror.url), child: Text(mirror.label)),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
                ]),
              ]),
            ),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// The gate that wraps the whole app
// ---------------------------------------------------------------------------

/// Sits above every screen. When an update is REQUIRED (or the app is a
/// modified copy) it covers the app completely and the screens underneath
/// can't be touched. For an optional update it shows the friendly sheet once.
class UpdateGate extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const UpdateGate({super.key, required this.child, required this.navigatorKey});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  DateTime _lastResumeCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool _promptShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UpdateService.instance.addListener(_maybePrompt);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UpdateService.instance.removeListener(_maybePrompt);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && DateTime.now().difference(_lastResumeCheck) > const Duration(minutes: 10)) {
      _lastResumeCheck = DateTime.now();
      UpdateService.instance.check();
    }
  }

  Future<void> _maybePrompt() async {
    if (_promptShown) return;
    final svc = UpdateService.instance;
    if (svc.status != UpdateStatus.optional || svc.manifest == null) return;
    if (!await svc.shouldPromptOptional()) return;
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    _promptShown = true;
    await svc.markPrompted();
    if (ctx.mounted) await showUpdateAvailableSheet(ctx, svc.manifest!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([UpdateService.instance, IntegrityService.instance]),
      builder: (context, _) {
        final tampered = IntegrityService.instance.tampered;
        final svc = UpdateService.instance;
        final required = svc.status == UpdateStatus.required && svc.manifest != null;
        final notice = (tampered || required) ? null : svc.activeNotice;
        final topInset = MediaQuery.of(context).padding.top;
        return Stack(
          children: [
            // The app underneath is frozen while covered. The structure here
            // never changes shape (only the banner slot grows and shrinks), so
            // the app's screens and their state are never rebuilt from scratch.
            IgnorePointer(
              ignoring: tampered || required,
              child: Column(
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    alignment: Alignment.topCenter,
                    child: notice == null ? const SizedBox(width: double.infinity) : NoticeBanner(key: ValueKey(notice.id), notice: notice, topInset: topInset),
                  ),
                  Expanded(
                    child: MediaQuery.removePadding(context: context, removeTop: notice != null, child: widget.child),
                  ),
                ],
              ),
            ),
            if (tampered)
              const Positioned.fill(child: TamperView())
            else if (required)
              Positioned.fill(child: UpdateRequiredView(manifest: svc.manifest!)),
          ],
        );
      },
    );
  }
}
