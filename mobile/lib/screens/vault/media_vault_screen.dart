import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/auth_service.dart';
import '../../services/biometric_unlock_service.dart';
import '../../services/media_vault_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../widgets/media_viewer_screen.dart';
import '../settings/forgot_password_screen.dart';
import 'vault_pin_screen.dart';

// ---------------------------------------------------------------------------
// Shared helpers for the vault screens
// ---------------------------------------------------------------------------

Route<T> _vaultRoute<T>(String name, Widget page) =>
    MaterialPageRoute<T>(settings: RouteSettings(name: name), builder: (_) => page);

String _formatWait(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '$s second${s == 1 ? '' : 's'}';
  final m = (s / 60).ceil();
  if (m < 60) return '$m minute${m == 1 ? '' : 's'}';
  final h = (m / 60).ceil();
  return '$h hour${h == 1 ? '' : 's'}';
}

void _snack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Asks for a NEW vault PIN twice (enter, then confirm). Returns the PIN, or
/// null if the person backed out. A PIN that's the same as the app PIN, or
/// isn't 4-8 digits, is refused by the first screen.
Future<String?> _askNewPin(BuildContext context, {required String title}) async {
  final vault = MediaVaultService.instance;
  final first = await Navigator.push<String>(
    context,
    _vaultRoute(
      '/vault/pin',
      VaultPinScreen(
        title: title,
        subtitle: 'Choose 4-8 digits that are different from your app PIN. Fingerprint/face is never used for this PIN.',
        onSubmit: (pin) => vault.newPinProblem(pin),
      ),
    ),
  );
  if (first == null || !context.mounted) return null;
  final second = await Navigator.push<String>(
    context,
    _vaultRoute(
      '/vault/pin',
      VaultPinScreen(
        title: 'Confirm your vault PIN',
        subtitle: 'Enter the same PIN again.',
        onSubmit: (pin) async => pin == first ? null : 'The two PINs do not match.',
      ),
    ),
  );
  if (second == null) return null;
  return first;
}

const _forgotPasswordMarker = '\u0000forgot-password';

/// "Forgot vault PIN?" step 1: re-check the ACCOUNT password with Firebase.
/// Returns true only if the password was right. If the person doesn't know
/// it, they're sent to the normal account password reset, and told to come
/// back and try again afterwards.
Future<bool> _confirmWithAccountPassword(BuildContext context) async {
  final controller = TextEditingController();
  var obscure = true;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Reset your vault PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter your NWisp account password to choose a new vault PIN. Everything in your vault is kept.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: obscure,
              autofocus: true,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                labelText: 'Account password',
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setDialogState(() => obscure = !obscure),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, _forgotPasswordMarker),
              child: const Text("I don't remember my account password"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('Confirm')),
        ],
      ),
    ),
  );
  if (result == null || result.isEmpty || !context.mounted) return false;

  if (result == _forgotPasswordMarker) {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()));
    _snack(context, 'Once your account password is reset, come back here and tap "Forgot PIN?" again.');
    return false;
  }
  try {
    await AuthService().reauthenticate(result);
    return true;
  } catch (_) {
    _snack(context, 'That account password is incorrect.');
    return false;
  }
}

// ---------------------------------------------------------------------------
// The vault
// ---------------------------------------------------------------------------

enum _View { loading, needsSetup, locked, unlocked }

/// Feature: locked media vault. Opened from the chat list's 3-dot menu.
///
/// Set up once with its own PIN (never the app PIN, never biometrics), it
/// holds photos and videos encrypted on this phone only. They get in by
/// long-pressing them in a chat ("Move to vault") or by adding them from the
/// phone's storage with the + button here.
class MediaVaultScreen extends StatefulWidget {
  const MediaVaultScreen({super.key});

  @override
  State<MediaVaultScreen> createState() => _MediaVaultScreenState();
}

class _MediaVaultScreenState extends State<MediaVaultScreen> with WidgetsBindingObserver {
  final _vault = MediaVaultService.instance;

  _View _view = _View.loading;
  VaultMode? _mode;
  List<VaultItem> _items = [];
  final Set<String> _selected = {};
  final Map<String, Future<Uint8List?>> _thumbFutures = {};
  bool _busy = false;
  bool _prompting = false;
  // The photo picker is a separate screen, so the app "pauses" while it is
  // open — that must not count as leaving the vault.
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Nothing in the vault may end up in a screenshot or the recents preview.
    ScreenshotGuardService.acquire();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ScreenshotGuardService.release();
    // Leaving the vault always locks it again.
    _vault.lock();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_pickerOpen) {
      // Switching away from the app locks the vault, whatever the app-lock
      // timing is set to.
      _vault.lock();
      if (mounted && _view == _View.unlocked) {
        setState(() {
          _view = _View.locked;
          _items = [];
          _selected.clear();
          _thumbFutures.clear();
        });
      }
    } else if (state == AppLifecycleState.resumed && _view == _View.locked && !_pickerOpen) {
      _bootstrap();
    }
  }

  // ---- Opening ---------------------------------------------------------

  Future<void> _bootstrap() async {
    if (_prompting) return;
    final setUp = await _vault.isSetUp();
    if (!mounted) return;
    if (!setUp) {
      setState(() => _view = _View.needsSetup);
      return;
    }
    final mode = await _vault.mode();
    if (!mounted) return;
    _mode = mode;
    if (_vault.isUnlocked) {
      await _loadItems();
      return;
    }
    setState(() => _view = _View.locked);
    if (mode == VaultMode.pin) {
      await _promptPin();
    } else {
      await _tryBiometric();
    }
  }

  Future<void> _promptPin() async {
    if (_prompting) return;
    _prompting = true;
    try {
      final result = await Navigator.push<String>(
        context,
        _vaultRoute(
          '/vault/pin',
          VaultPinScreen(
            title: 'Vault PIN',
            subtitle: 'Enter your media vault PIN.',
            submitLabel: 'Unlock',
            onSubmit: (pin) async {
              final r = await _vault.unlockWithPin(pin);
              if (r.ok) return null;
              if (r.lockedFor != null) {
                return 'Too many wrong tries. Try again in ${_formatWait(r.lockedFor!)}.';
              }
              return 'Incorrect PIN. ${r.attemptsLeft} ${r.attemptsLeft == 1 ? 'try' : 'tries'} left before a short lock.';
            },
            footerLabel: 'Forgot PIN?',
            onFooter: _forgotPin,
          ),
        ),
      );
      if (!mounted) return;
      if (_vault.isUnlocked) {
        await _loadItems();
      } else if (result == null) {
        // Backed out of the PIN screen without unlocking — leave the vault.
        Navigator.pop(context);
      }
    } finally {
      _prompting = false;
    }
  }

  Future<void> _tryBiometric() async {
    if (_prompting) return;
    _prompting = true;
    try {
      final ok = await _vault.unlockWithBiometric();
      if (!mounted) return;
      if (ok) await _loadItems();
    } finally {
      _prompting = false;
    }
  }

  /// "Forgot PIN?" — account password first, then a fresh PIN. Everything in
  /// the vault is kept. (Only offered in PIN mode; biometric-only mode has
  /// no such path, and the service refuses it too.)
  Future<bool> _forgotPin(BuildContext pinContext) async {
    if (!await _confirmWithAccountPassword(pinContext)) return false;
    if (!pinContext.mounted) return false;
    final newPin = await _askNewPin(pinContext, title: 'Choose a new vault PIN');
    if (newPin == null) return false;
    try {
      await _vault.resetPin(newPin);
      return true;
    } catch (e) {
      _snack(pinContext, "Couldn't reset the PIN: $e");
      return false;
    }
  }

  Future<void> _setUp() async {
    final pin = await _askNewPin(context, title: 'Create your vault PIN');
    if (pin == null || !mounted) return;
    try {
      await _vault.setUp(pin);
      _mode = VaultMode.pin;
      await _loadItems();
    } catch (e) {
      _snack(context, "Couldn't set up the vault: $e");
    }
  }

  Future<void> _loadItems() async {
    try {
      final items = await _vault.listItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _selected.clear();
        _view = _View.unlocked;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _view = _View.locked);
      _snack(context, "Couldn't open the vault.");
    }
  }

  // ---- Contents --------------------------------------------------------

  bool _looksLikeVideo(XFile f) {
    final mime = f.mimeType?.toLowerCase();
    if (mime != null) return mime.startsWith('video/');
    final path = f.path.toLowerCase();
    return const ['.mp4', '.mov', '.m4v', '.3gp', '.mkv', '.webm', '.avi'].any(path.endsWith);
  }

  Future<void> _addFromStorage() async {
    if (_busy) return;
    List<XFile> picked;
    _pickerOpen = true;
    try {
      picked = await ImagePicker().pickMultipleMedia();
    } catch (_) {
      _pickerOpen = false;
      _snack(context, "Couldn't open your photo library.");
      return;
    }
    _pickerOpen = false;
    if (picked.isEmpty || !mounted) return;

    setState(() => _busy = true);
    var added = 0;
    for (final x in picked) {
      try {
        await _vault.importFile(File(x.path), isVideo: _looksLikeVideo(x));
        added++;
      } catch (_) {}
    }
    if (!mounted) return;
    await _loadItems();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      context,
      added == 0
          ? "Couldn't add those to the vault."
          : '$added added. The originals are still in your gallery — delete them there if you want them only in the vault.',
    );
  }

  Future<void> _openItem(VaultItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    File? temp;
    try {
      final file = await _vault.decryptToTemp(item);
      temp = file;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MediaViewerScreen(
            items: [MediaViewerItem(path: file.path, isVideo: item.isVideo)],
            initialIndex: 0,
          ),
        ),
      );
    } catch (_) {
      if (mounted) _snack(context, "Couldn't open this item.");
    } finally {
      // The decrypted copy never outlives the viewer.
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $count ${count == 1 ? 'item' : 'items'}?'),
        content: const Text('They will be permanently deleted from your vault. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _vault.deleteItems(_selected.toList());
    } catch (_) {
      if (mounted) _snack(context, "Couldn't delete those.");
    }
    if (mounted) await _loadItems();
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<String>(
      context,
      _vaultRoute('/vault/settings', const _VaultSettingsScreen()),
    );
    if (!mounted) return;
    if (result == 'locked' || result == 'deleted') {
      _vault.lock();
      Navigator.pop(context);
      return;
    }
    _mode = await _vault.mode();
    if (mounted) setState(() {});
  }

  // ---- UI --------------------------------------------------------------

  PreferredSizeWidget _buildAppBar() {
    if (_view == _View.unlocked && _selected.isNotEmpty) {
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
        title: Text('${_selected.length} selected'),
        actions: [
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: _deleteSelected),
        ],
      );
    }
    return AppBar(
      title: const Text('Media vault'),
      actions: _view == _View.unlocked
          ? [
              IconButton(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                tooltip: 'Add from your phone',
                onPressed: _addFromStorage,
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'settings') {
                    _openSettings();
                  } else if (value == 'lock') {
                    _vault.lock();
                    Navigator.pop(context);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'settings',
                    child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Vault settings'), contentPadding: EdgeInsets.zero),
                  ),
                  PopupMenuItem(
                    value: 'lock',
                    child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Lock vault now'), contentPadding: EdgeInsets.zero),
                  ),
                ],
              ),
            ]
          : null,
    );
  }

  Widget _centered(List<Widget> children) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );

  Widget _buildBody(ColorScheme scheme) {
    switch (_view) {
      case _View.loading:
        return const Center(child: CircularProgressIndicator());

      case _View.needsSetup:
        return _centered([
          Icon(Icons.enhanced_encryption_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: 16),
          Text('Media vault', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(
            'A locked, encrypted place on this phone for photos and videos you want kept private.\n\n'
            'It has its own PIN — different from your app PIN, and never opened by fingerprint unless you choose '
            'biometric-only later. Everything stays on this phone.\n\n'
            'Move photos in by long-pressing them in a chat, or add them from your phone with the + button.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: _setUp, icon: const Icon(Icons.pin_outlined), label: const Text('Set up vault PIN')),
        ]);

      case _View.locked:
        if (_mode == VaultMode.biometric) {
          // Biometric-only mode: exactly one thing on screen. No PIN, no
          // "forgot", no reset, nothing else to try.
          return _centered([
            Icon(Icons.fingerprint, size: 72, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Vault locked', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _tryBiometric,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Unlock with biometrics'),
            ),
          ]);
        }
        return _centered([
          Icon(Icons.lock_outline_rounded, size: 64, color: scheme.primary),
          const SizedBox(height: 16),
          Text('Vault locked', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: _promptPin, icon: const Icon(Icons.pin_outlined), label: const Text('Enter PIN')),
        ]);

      case _View.unlocked:
        if (_items.isEmpty) {
          return _centered([
            Icon(Icons.photo_library_outlined, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Your vault is empty', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Long-press a photo or video in any chat and choose "Move to vault", or tap + to add from your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ]);
        }
        return Stack(
          children: [
            GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _items.length,
              itemBuilder: (context, i) => _buildTile(_items[i], scheme),
            ),
            if (_busy) const Positioned.fill(child: ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator()))),
          ],
        );
    }
  }

  Widget _buildTile(VaultItem item, ColorScheme scheme) {
    final selected = _selected.contains(item.id);
    final thumb = _thumbFutures.putIfAbsent(item.id, () => _vault.thumbnail(item));
    return GestureDetector(
      onTap: () {
        if (_selected.isNotEmpty) {
          setState(() => selected ? _selected.remove(item.id) : _selected.add(item.id));
        } else {
          _openItem(item);
        }
      },
      onLongPress: () => setState(() => selected ? _selected.remove(item.id) : _selected.add(item.id)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: scheme.surfaceContainerHighest,
            child: FutureBuilder<Uint8List?>(
              future: thumb,
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes != null) return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
                return Icon(item.isVideo ? Icons.videocam_outlined : Icons.image_outlined, color: scheme.onSurfaceVariant);
              },
            ),
          ),
          if (item.isVideo)
            const Positioned(right: 6, bottom: 6, child: Icon(Icons.play_circle_fill, color: Colors.white, size: 22)),
          // Feature: intruder photo — a red label with the date and time the
          // wrong PINs were entered.
          if (item.isIntruder)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                color: Colors.red.shade700.withValues(alpha: 0.9),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 12, color: Colors.white),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        'Intruder · ${_intruderStamp(item.addedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (selected)
            Container(
              color: scheme.primary.withValues(alpha: 0.35),
              child: const Center(child: Icon(Icons.check_circle, color: Colors.white)),
            ),
        ],
      ),
    );
  }

  static String _intruderStamp(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]} $h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(appBar: _buildAppBar(), body: _buildBody(scheme));
  }
}

// ---------------------------------------------------------------------------
// Vault settings (the vault's own 3-dot menu -> "Vault settings")
// ---------------------------------------------------------------------------

class _VaultSettingsScreen extends StatefulWidget {
  const _VaultSettingsScreen();

  @override
  State<_VaultSettingsScreen> createState() => _VaultSettingsScreenState();
}

class _VaultSettingsScreenState extends State<_VaultSettingsScreen> {
  final _vault = MediaVaultService.instance;
  VaultMode? _mode;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    _refresh();
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    super.dispose();
  }

  Future<void> _refresh() async {
    final mode = await _vault.mode();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _loading = false;
    });
  }

  Future<String?> _verifyCurrentPin(String pin) async {
    final r = await _vault.unlockWithPin(pin);
    if (r.ok) return null;
    if (r.lockedFor != null) return 'Too many wrong tries. Try again in ${_formatWait(r.lockedFor!)}.';
    return 'Incorrect PIN.';
  }

  Future<void> _changePin() async {
    final current = await Navigator.push<String>(
      context,
      _vaultRoute(
        '/vault/pin',
        VaultPinScreen(title: 'Current vault PIN', subtitle: 'Enter your current PIN first.', onSubmit: _verifyCurrentPin),
      ),
    );
    if (current == null || !mounted) return;
    final newPin = await _askNewPin(context, title: 'Choose a new vault PIN');
    if (newPin == null || !mounted) return;
    try {
      await _vault.resetPin(newPin);
      _snack(context, 'Vault PIN changed.');
    } catch (e) {
      _snack(context, "Couldn't change the PIN: $e");
    }
  }

  Future<void> _enableBiometricOnly() async {
    if (!await BiometricUnlockService.isAvailable()) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Biometrics not set up'),
          content: const Text(
            'This phone has no fingerprint or face unlock set up. Add one in your phone\'s settings, then come back to turn this on.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK'))],
        ),
      );
      return;
    }
    if (!mounted) return;
    final agreed = await showDialog<bool>(context: context, builder: (_) => const _BiometricOnlyWarningDialog());
    if (agreed != true || !mounted) return;

    setState(() => _busy = true);
    final ok = await _vault.enableBiometricOnly();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _refresh();
      if (mounted) _snack(context, 'Biometric-only unlock is on. The vault PIN has been deleted.');
    } else {
      _snack(context, "Couldn't confirm your biometrics — nothing was changed.");
    }
  }

  Future<void> _disableBiometricOnly() async {
    final newPin = await _askNewPin(context, title: 'Choose a vault PIN');
    if (newPin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await _vault.disableBiometricOnly(newPin);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        await _refresh();
        if (mounted) _snack(context, 'Biometric-only unlock is off. Your new PIN is set.');
      } else {
        _snack(context, "Couldn't confirm your biometrics — nothing was changed.");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(context, "Couldn't turn it off: $e");
    }
  }

  Future<void> _deleteVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined),
        title: const Text('Delete the vault?'),
        content: const Text(
          'Every photo and video in the vault will be permanently deleted from this phone, along with the vault PIN. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Prove it's really them first — the vault PIN, or biometrics in
    // biometric-only mode.
    bool proven;
    if (_mode == VaultMode.pin) {
      final pin = await Navigator.push<String>(
        context,
        _vaultRoute(
          '/vault/pin',
          VaultPinScreen(
            title: 'Enter vault PIN',
            subtitle: 'Confirm your PIN to delete the vault.',
            submitLabel: 'Delete vault',
            onSubmit: _verifyCurrentPin,
          ),
        ),
      );
      proven = pin != null;
    } else {
      proven = await BiometricUnlockService.authenticate(reason: 'Confirm deleting your media vault');
    }
    if (!proven || !mounted) return;
    await _vault.wipeAll();
    if (mounted) Navigator.pop(context, 'deleted');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final biometricOnly = _mode == VaultMode.biometric;
    return Scaffold(
      appBar: AppBar(title: const Text('Vault settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ListView(
                  children: [
                    if (!biometricOnly)
                      ListTile(
                        leading: const Icon(Icons.pin_outlined),
                        title: const Text('Change vault PIN'),
                        subtitle: const Text('Asks for your current vault PIN first'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _changePin,
                      ),
                    SwitchListTile.adaptive(
                      secondary: const Icon(Icons.fingerprint),
                      title: const Text('Biometric-only unlock'),
                      subtitle: Text(
                        biometricOnly
                            ? 'On — only your fingerprint or face opens the vault. There is no PIN and no reset.'
                            : 'Open the vault with ONLY your fingerprint or face. Removes the vault PIN and the account-password reset, '
                                'so nobody who just knows your passwords can get in.',
                      ),
                      value: biometricOnly,
                      onChanged: _busy ? null : (v) => v ? _enableBiometricOnly() : _disableBiometricOnly(),
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: const Text('Lock vault now'),
                      onTap: () => Navigator.pop(context, 'locked'),
                    ),
                    ListTile(
                      leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
                      title: Text('Delete vault', style: TextStyle(color: scheme.error)),
                      subtitle: const Text('Permanently deletes everything in it'),
                      onTap: _deleteVault,
                    ),
                  ],
                ),
                if (_busy) const Positioned.fill(child: ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator()))),
              ],
            ),
    );
  }
}

/// The warning shown at the moment someone turns biometric-only unlock on.
/// "Turn on" stays disabled until they tick that they understand.
class _BiometricOnlyWarningDialog extends StatefulWidget {
  const _BiometricOnlyWarningDialog();

  @override
  State<_BiometricOnlyWarningDialog> createState() => _BiometricOnlyWarningDialogState();
}

class _BiometricOnlyWarningDialogState extends State<_BiometricOnlyWarningDialog> {
  bool _understood = false;

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(child: Text(text)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('Turn on biometric-only unlock?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bullet('Your vault PIN will be permanently deleted.'),
            _bullet(
              'There will be no "Forgot PIN" and no reset with your account password. '
              'Someone who knows your account password still cannot open the vault.',
            ),
            _bullet(
              'If your fingerprints or face are removed or changed, the sensor stops working, or you move to a new phone, '
              'the photos and videos in the vault CANNOT be recovered — not by you, not by us.',
            ),
            _bullet('You can switch this off later, but only after unlocking with your biometrics.'),
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
              title: const Text('I understand and want to turn this on'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _understood ? () => Navigator.pop(context, true) : null, child: const Text('Turn on')),
      ],
    );
  }
}
