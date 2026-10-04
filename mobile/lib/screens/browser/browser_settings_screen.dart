import 'package:flutter/material.dart';
import '../../services/browser_data_service.dart';
import '../../services/browser_settings_service.dart';
import '../../widgets/nwisp_ui.dart';
import 'browser_library_screen.dart';

/// Shows the warning that must be accepted before the in-app browser is
/// turned off. Returns true if the person still wants to turn it off.
Future<bool> confirmDisableInAppBrowser(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: Theme.of(ctx).colorScheme.error, size: 36),
      title: const Text('Turn off the in-app browser?'),
      content: const Text(
        "If it's off, links will open in your phone's default browser. That can cause your details to get tracked "
        '(history, cookies, ads profile, your IP address and more), and NWisp can no longer block trackers for you.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it on')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Turn off'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Settings > Private browser (also reachable from the browser's own menu).
class BrowserSettingsScreen extends StatefulWidget {
  const BrowserSettingsScreen({super.key});

  @override
  State<BrowserSettingsScreen> createState() => _BrowserSettingsScreenState();
}

class _BrowserSettingsScreenState extends State<BrowserSettingsScreen> {
  final s = BrowserSettingsService.instance;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    s.load().then((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  Widget _switch(ValueNotifier<bool> n, String title, String subtitle, Future<void> Function(bool) set, {IconData? icon}) {
    return ValueListenableBuilder<bool>(
      valueListenable: n,
      builder: (_, v, __) => SwitchListTile(
        secondary: icon == null ? null : Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
        value: v,
        onChanged: (nv) => set(nv),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Private browser')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                NwispCard(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: s.enabled,
                    builder: (_, on, __) => SwitchListTile(
                      secondary: const Icon(Icons.shield_moon_rounded),
                      title: const Text('Open links in NWisp', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        on
                            ? 'Links from chats open in the private browser inside the app.'
                            : "Off — links open in your phone's default browser, which can track you.",
                        style: TextStyle(fontSize: 12.5, color: on ? null : scheme.error),
                      ),
                      value: on,
                      onChanged: (v) async {
                        if (v) {
                          await s.setEnabled(true);
                        } else if (await confirmDisableInAppBrowser(context)) {
                          await s.setEnabled(false);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.fromLTRB(6, 4, 6, 6),
                  child: Text('Privacy protections', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                NwispCard(
                  child: Column(
                    children: [
                      _switch(s.highPrivacy, 'High privacy mode', 'Hides your device fingerprint, blocks WebRTC IP leaks, sends no Referer, hides camera/mic/sensor/battery info from sites', s.setHighPrivacy, icon: Icons.security_rounded),
                      const Divider(height: 1, indent: 56),
                      _switch(s.stripTrackingParams, 'Clean tracking links', 'Removes utm_, fbclid, gclid and similar tracking bits from links', s.setStripTrackingParams, icon: Icons.cleaning_services_outlined),
                      const Divider(height: 1, indent: 56),
                      _switch(s.blockTrackers, 'Block trackers & ads', 'Stops known tracking and advertising servers', s.setBlockTrackers, icon: Icons.block_rounded),
                      const Divider(height: 1, indent: 56),
                      _switch(s.blockThirdPartyCookies, 'Block third-party cookies', 'Sites can\'t follow you around through embedded content', s.setBlockThirdPartyCookies, icon: Icons.cookie_outlined),
                      const Divider(height: 1, indent: 56),
                      _switch(s.httpsOnly, 'HTTPS only', 'Upgrade http:// pages to secure https://', s.setHttpsOnly, icon: Icons.https_rounded),
                      const Divider(height: 1, indent: 56),
                      _switch(s.clearOnExit, 'Clear data when closing', 'Delete cookies, cache and site data when you close the browser', s.setClearOnExit, icon: Icons.delete_sweep_outlined),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.fromLTRB(6, 4, 6, 6),
                  child: Text('Browsing', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                NwispCard(
                  child: Column(
                    children: [
                      ValueListenableBuilder<String>(
                        valueListenable: s.searchEngine,
                        builder: (_, engine, __) => ListTile(
                          leading: const Icon(Icons.search_rounded),
                          title: const Text('Search engine', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(s.searchName, style: const TextStyle(fontSize: 12.5)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final picked = await showModalBottomSheet<String>(
                              context: context,
                              showDragHandle: true,
                              builder: (ctx) => SafeArea(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final e in BrowserSettingsService.engines.entries)
                                      ListTile(
                                        title: Text(e.value.$1),
                                        subtitle: e.key == 'google' ? const Text('Tracks searches — not recommended', style: TextStyle(fontSize: 12)) : null,
                                        trailing: e.key == engine ? const Icon(Icons.check) : null,
                                        onTap: () => Navigator.pop(ctx, e.key),
                                      ),
                                  ],
                                ),
                              ),
                            );
                            if (picked != null) await s.setSearchEngine(picked);
                          },
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      _switch(s.javascript, 'JavaScript', 'Turn off for maximum privacy — many sites will break', s.setJavascript, icon: Icons.code_rounded),
                      const Divider(height: 1, indent: 56),
                      _switch(s.desktopMode, 'Desktop site', 'Ask sites for their desktop version', s.setDesktopMode, icon: Icons.desktop_windows_outlined),
                      const Divider(height: 1, indent: 56),
                      _switch(s.saveHistory, 'Save browsing history', 'Off by default. If on, pages you visit are listed (on this phone only, encrypted)', s.setSaveHistory, icon: Icons.history_rounded),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.bookmarks_outlined),
                        title: const Text('Bookmarks & history', style: TextStyle(fontWeight: FontWeight.w600)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserLibraryScreen())),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: Icon(Icons.delete_outline, color: scheme.error),
                        title: const Text('Clear browsing history now', style: TextStyle(fontWeight: FontWeight.w600)),
                        onTap: () async {
                          await BrowserDataService.instance.clearHistory();
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History cleared')));
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                NwispCard(
                  child: ListTile(
                    leading: Icon(Icons.info_outline, color: scheme.primary),
                    title: const Text('How private is it?', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                      "It runs on your phone's built-in web engine, so it can't fully match a dedicated privacy browser like Brave. "
                      'It remembers nothing, blocks known trackers, refuses third-party cookies and upgrades to https. '
                      'It cannot hide your IP address from the sites you visit (use a VPN for that). '
                      'Changes apply the next time you open the browser.',
                      style: TextStyle(fontSize: 12.5, height: 1.35),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
