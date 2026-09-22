import 'package:flutter/material.dart';
import '../../services/privacy_checkup_service.dart';
import '../security/pin_screen.dart';
import 'privacy_lockdown_screen.dart';

/// Turns one check on/off, showing a plain message if it fails (for
/// example while offline). Shared by the list and the step-by-step pages.
Future<void> togglePrivacyItem(BuildContext context, PrivacyItem item, bool on) async {
  try {
    await PrivacyCheckupService.setItem(item.id, on);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't change that — check your connection and try again.")),
      );
    }
  }
}

/// One row of the checkup: a switch, or — for the app lock — a "Set up" row
/// that opens the PIN screen (the PIN is yours to choose, so it can never be
/// switched on for you).
class PrivacyItemTile extends StatelessWidget {
  final PrivacyItem item;
  final Map<String, dynamic> raw;
  final Future<void> Function(bool on) onToggle;
  final VoidCallback onSetUpLock;

  const PrivacyItemTile({super.key, required this.item, required this.raw, required this.onToggle, required this.onSetUpLock});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = PrivacyCheckupService.isOn(item.id, raw);
    final lockOn = raw['appLock'] == true;

    if (item.id == 'app_lock') {
      return ListTile(
        leading: Icon(item.icon, color: on ? scheme.primary : scheme.onSurfaceVariant),
        title: Text(item.title),
        subtitle: Text(on ? 'On — your app asks for a PIN' : item.description),
        trailing: on ? Icon(Icons.check_circle, color: scheme.primary) : FilledButton.tonal(onPressed: onSetUpLock, child: const Text('Set up')),
        onTap: on ? null : onSetUpLock,
      );
    }
    final blocked = item.needsAppLock && !lockOn;
    return SwitchListTile.adaptive(
      secondary: Icon(item.icon, color: on ? scheme.primary : scheme.onSurfaceVariant),
      title: Text(item.title),
      subtitle: Text(blocked ? 'Turn on App lock first' : item.description),
      value: on,
      onChanged: blocked ? null : (v) => onToggle(v),
    );
  }
}

/// Settings > Privacy checkup: how many of the 12 privacy / security
/// settings are on, a step-by-step walkthrough, and a "Make it 100%
/// private" button that shows exactly what it will change before doing it.
class PrivacyCheckupScreen extends StatefulWidget {
  const PrivacyCheckupScreen({super.key});

  @override
  State<PrivacyCheckupScreen> createState() => _PrivacyCheckupScreenState();
}

class _PrivacyCheckupScreenState extends State<PrivacyCheckupScreen> {
  Map<String, dynamic>? _raw;
  bool _hasUndo = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final raw = await PrivacyCheckupService.readRaw();
    final undo = await PrivacyCheckupService.hasUndo();
    if (!mounted) return;
    setState(() {
      _raw = raw;
      _hasUndo = undo;
    });
  }

  Future<void> _setUpLock() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)));
    await _reload();
  }

  Future<void> _openLockdown() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyLockdownScreen()));
    await _reload();
  }

  Future<void> _openWalkthrough() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyWalkthroughScreen()));
    await _reload();
  }

  Future<void> _undo() async {
    await PrivacyCheckupService.undoLastLockdown();
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your earlier settings are back.')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = _raw;
    if (raw == null) {
      return Scaffold(appBar: AppBar(title: const Text('Privacy checkup')), body: const Center(child: CircularProgressIndicator()));
    }
    final total = kPrivacyItems.length;
    final score = PrivacyCheckupService.score(raw);
    final perfect = score == total;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy checkup')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: CircularProgressIndicator(
                          value: score / total,
                          strokeWidth: 10,
                          backgroundColor: scheme.surfaceContainerHighest,
                          color: perfect ? Colors.green : scheme.primary,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$score of $total', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                          Text('are on', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  perfect ? "You're fully protected" : (score >= 8 ? 'Nearly there' : 'Room to make this more private'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  perfect
                      ? 'Every privacy and security setting in this checkup is on.'
                      : 'Go through them one by one, or switch them all on in one tap.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (!perfect)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openLockdown,
                      icon: const Icon(Icons.shield_outlined),
                      label: const Text('Make it 100% private'),
                    ),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openWalkthrough,
                    icon: const Icon(Icons.checklist_rtl),
                    label: const Text('Go through it step by step'),
                  ),
                ),
                if (_hasUndo)
                  TextButton.icon(
                    onPressed: _undo,
                    icon: const Icon(Icons.undo),
                    label: const Text('Undo the last "100% private"'),
                  ),
              ],
            ),
          ),
          for (final step in PrivacyStep.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
              child: Text(step.title, style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
            ),
            for (final item in kPrivacyItems.where((i) => i.step == step))
              PrivacyItemTile(
                item: item,
                raw: raw,
                onToggle: (on) async {
                  await togglePrivacyItem(context, item, on);
                  await _reload();
                },
                onSetUpLock: _setUpLock,
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Text(
              'Not part of this checkup: auto-delete messages and auto-wipe. They delete things, so they are always your own choice in Settings.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// The guided version: one page per topic, Back / Next, and a summary at the
/// end.
class PrivacyWalkthroughScreen extends StatefulWidget {
  const PrivacyWalkthroughScreen({super.key});

  @override
  State<PrivacyWalkthroughScreen> createState() => _PrivacyWalkthroughScreenState();
}

class _PrivacyWalkthroughScreenState extends State<PrivacyWalkthroughScreen> {
  Map<String, dynamic>? _raw;
  int _page = 0; // 0..3 = steps, 4 = summary

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final raw = await PrivacyCheckupService.readRaw();
    if (mounted) setState(() => _raw = raw);
  }

  Future<void> _setUpLock() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = _raw;
    final steps = PrivacyStep.values;
    final onSummary = _page >= steps.length;
    return Scaffold(
      appBar: AppBar(title: Text(onSummary ? 'All done' : 'Step ${_page + 1} of ${steps.length}')),
      body: raw == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                LinearProgressIndicator(value: (_page + 1) / (steps.length + 1)),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: onSummary
                        ? [
                            const SizedBox(height: 32),
                            Icon(Icons.verified_user_outlined, size: 72, color: scheme.primary),
                            const SizedBox(height: 16),
                            Center(
                              child: Text(
                                '${PrivacyCheckupService.score(raw)} of ${kPrivacyItems.length} settings are on',
                                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                PrivacyCheckupService.score(raw) == kPrivacyItems.length
                                    ? "You're fully protected."
                                    : 'You can switch the rest on any time from the checkup screen — or use "Make it 100% private".',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ]
                        : [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                              child: Text(steps[_page].title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Text(steps[_page].intro, style: TextStyle(color: scheme.onSurfaceVariant)),
                            ),
                            for (final item in kPrivacyItems.where((i) => i.step == steps[_page]))
                              PrivacyItemTile(
                                item: item,
                                raw: raw,
                                onToggle: (on) async {
                                  await togglePrivacyItem(context, item, on);
                                  await _reload();
                                },
                                onSetUpLock: _setUpLock,
                              ),
                          ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        if (_page > 0 && !onSummary)
                          Expanded(child: OutlinedButton(onPressed: () => setState(() => _page--), child: const Text('Back')))
                        else
                          const Spacer(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              if (onSummary) {
                                Navigator.pop(context);
                              } else {
                                setState(() => _page++);
                              }
                            },
                            child: Text(onSummary ? 'Done' : (_page == steps.length - 1 ? 'Finish' : 'Next')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
