import 'package:flutter/material.dart';
import '../../services/permission_service.dart';

/// Permissions — used twice:
///  * [intro] = true: the first-start screen ("Allow everything" / "Not now").
///  * Settings → Permissions: see which are allowed, allow one, allow all, or
///    jump to the phone's settings page to turn any of them off.
class PermissionsScreen extends StatefulWidget {
  final bool intro;
  const PermissionsScreen({super.key, this.intro = false});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  final Map<String, bool> _granted = {};
  final Map<String, bool> _blocked = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the phone's settings page → show the new state.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final p in PermissionService.all) {
      _granted[p.id] = await PermissionService.isGranted(p);
      _blocked[p.id] = await PermissionService.isPermanentlyDenied(p);
    }
    if (mounted) setState(() {});
  }

  Future<void> _allowOne(AppPermission p) async {
    if (_blocked[p.id] == true) {
      await PermissionService.openSystemSettings();
      return;
    }
    setState(() => _busy = true);
    await PermissionService.request(p);
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _allowAll() async {
    setState(() => _busy = true);
    await PermissionService.requestAll();
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _finishIntro() async {
    await PermissionService.markIntroSeen();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final grantedCount = PermissionService.all.where((p) => _granted[p.id] == true).length;
    final list = ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (widget.intro)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Column(
              children: [
                Icon(Icons.verified_user_outlined, size: 54, color: scheme.primary),
                const SizedBox(height: 12),
                Text('Allow NWisp to work fully', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Calls, voice messages, QR scanning, nearby chat and notifications each need a permission. '
                  'You can change any of them later in Settings → Permissions.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '$grantedCount of ${PermissionService.all.length} allowed',
              style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _allowAll,
                  icon: _busy
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.done_all_rounded),
                  label: const Text('Allow all'),
                ),
              ),
              if (!widget.intro) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: PermissionService.openSystemSettings,
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('Turn off…'),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (!widget.intro)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Android only lets the phone\'s own Settings page take a permission back, so "Turn off" and the switches below open it.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
          ),
        for (final p in PermissionService.all)
          SwitchListTile.adaptive(
            secondary: Icon(p.icon),
            title: Text(p.title),
            subtitle: Text(p.special ? p.why : '${p.why}${_blocked[p.id] == true ? '\nBlocked — open phone settings to allow.' : ''}'),
            isThreeLine: _blocked[p.id] == true,
            value: _granted[p.id] == true,
            onChanged: _busy
                ? null
                : (v) {
                    if (v) {
                      _allowOne(p);
                    } else {
                      PermissionService.openSystemSettings();
                    }
                  },
          ),
      ],
    );

    if (!widget.intro) {
      return Scaffold(appBar: AppBar(title: const Text('Permissions')), body: list);
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finishIntro();
      },
      child: Scaffold(
        body: SafeArea(child: list),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextButton(onPressed: _finishIntro, child: const Text('Continue')),
          ),
        ),
      ),
    );
  }
}
