import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/backup_service.dart';

/// Settings → Backup and restore.
///
/// Make a passphrase-protected backup file of your chats, save it somewhere
/// safe (Drive, your computer …), and restore it on a new phone or after a
/// reinstall. NWisp never sees your passphrase: lose it and the file cannot be
/// opened by anyone.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  final _restorePass = TextEditingController();
  bool _includeMedia = true;
  bool _obscure = true;

  bool _busy = false;
  double _progress = 0;
  String _step = '';
  String? _error;
  String? _info;

  File? _pickedFile;
  String? _pickedName;

  @override
  void dispose() {
    _pass.dispose();
    _pass2.dispose();
    _restorePass.dispose();
    super.dispose();
  }

  bool get _canCreate => _pass.text.length >= 8 && _pass.text == _pass2.text && !_busy;

  void _onProgress(double v, String step) {
    if (!mounted) return;
    setState(() {
      _progress = v;
      _step = step;
    });
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _progress = 0;
      _step = 'Starting…';
    });
    try {
      final (file, summary) = await BackupService.instance.create(
        passphrase: _pass.text,
        includeMedia: _includeMedia,
        onProgress: _onProgress,
      );
      if (!mounted) return;
      setState(() => _info = 'Backup ready: ${summary.messages} messages${summary.media > 0 ? ', ${summary.media} media files' : ''}. Choose where to save it.');
      await Share.shareXFiles([XFile(file.path)], subject: 'NWisp backup');
      // The temporary copy isn't needed once the person has chosen where it goes.
      try {
        await file.delete();
      } catch (_) {}
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) return;
    setState(() {
      _pickedFile = File(result.files.single.path!);
      _pickedName = result.files.single.name;
      _error = null;
      _info = null;
    });
  }

  Future<void> _restore() async {
    final file = _pickedFile;
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _progress = 0;
      _step = 'Starting…';
    });
    try {
      final summary = await BackupService.instance.restore(file: file, passphrase: _restorePass.text, onProgress: _onProgress);
      if (!mounted) return;
      setState(() => _info = 'Restored ${summary.messages} messages${summary.media > 0 ? ' and ${summary.media} media files' : ''}.');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup and restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.secondaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(14)),
            child: Text(
              'Your chats live only on this phone. A backup lets you bring them to a new phone or after a reinstall.\n\n'
              '• The file is locked with your passphrase. NWisp never sees it — if you lose it, the backup can\'t be opened by anyone.\n'
              '• Encryption keys are not included, so after restoring, your contacts will see a "security code changed" notice. That is normal for a new phone.\n'
              '• Stories are not included (they disappear after 24 hours).',
              style: TextStyle(color: scheme.onSecondaryContainer, height: 1.4, fontSize: 13.5),
            ),
          ),
          const SizedBox(height: 22),
          Text('CREATE A BACKUP', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.6)),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            obscureText: _obscure,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Passphrase (at least 8 characters)',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pass2,
            obscureText: _obscure,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Repeat passphrase',
              prefixIcon: const Icon(Icons.key_outlined),
              errorText: _pass2.text.isNotEmpty && _pass.text != _pass2.text ? "Doesn't match" : null,
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include photos, videos and voice messages'),
            subtitle: const Text('Makes the file bigger'),
            value: _includeMedia,
            onChanged: _busy ? null : (v) => setState(() => _includeMedia = v),
          ),
          FilledButton.icon(
            onPressed: _canCreate ? _create : null,
            icon: const Icon(Icons.backup_outlined),
            label: const Text('Create backup'),
          ),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 14),
          Text('RESTORE FROM A BACKUP', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.6)),
          const SizedBox(height: 8),
          Text(
            'Sign in to the same NWisp account first. Messages already on this phone are kept.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.folder_open_outlined),
            label: Text(_pickedName ?? 'Choose backup file'),
          ),
          if (_pickedFile != null) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _restorePass,
              obscureText: true,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Backup passphrase', prefixIcon: Icon(Icons.key_outlined)),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: (!_busy && _restorePass.text.isNotEmpty) ? _restore : null,
              icon: const Icon(Icons.settings_backup_restore_rounded),
              label: const Text('Restore'),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 20),
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 6),
            Text(_step, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600))),
          if (_info != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_info!, style: TextStyle(color: Colors.green.shade600, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
