import 'package:flutter/material.dart';
import '../../services/auto_download_service.dart';
import '../../services/contact_service.dart';
import '../../services/local_message_store.dart';
import '../../services/nickname_service.dart';

/// Settings → Data and storage:
///  * Auto-download rules: for photos, videos and voice messages — always,
///    Wi-Fi only, or never.
///  * Storage manager: how much room each chat's media takes, and clear it by
///    chat or by type. Clearing removes the saved FILES only; the messages
///    stay in the chat and show "unavailable" in place of the file.
class DataStorageScreen extends StatefulWidget {
  const DataStorageScreen({super.key});

  @override
  State<DataStorageScreen> createState() => _DataStorageScreenState();
}

class _ChatUsage {
  final String id;
  String name;
  int image = 0, video = 0, voice = 0;
  _ChatUsage(this.id, this.name);
  int get total => image + video + voice;
}

class _DataStorageScreenState extends State<DataStorageScreen> {
  final _auto = AutoDownloadService.instance;
  bool _loading = true;
  int _image = 0, _video = 0, _voice = 0;
  List<_ChatUsage> _chats = [];

  static const _labels = {'image': 'Photos', 'video': 'Videos', 'voice': 'Voice messages'};
  static const _icons = {'image': Icons.image_outlined, 'video': Icons.videocam_outlined, 'voice': Icons.mic_none_rounded};

  @override
  void initState() {
    super.initState();
    _auto.load().then((_) {
      if (mounted) setState(() {});
    });
    NicknameService.instance.load();
    _scan();
  }

  static String fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _scan() async {
    setState(() => _loading = true);
    try {
      final files = await LocalMessageStore.mediaFiles();
      final groups = await LocalMessageStore.groupNames();
      final byChat = <String, _ChatUsage>{};
      var img = 0, vid = 0, voi = 0;
      for (final f in files) {
        final u = byChat.putIfAbsent(f.conversationId, () => _ChatUsage(f.conversationId, groups[f.conversationId] ?? ''));
        switch (f.type) {
          case 'image':
            u.image += f.bytes;
            img += f.bytes;
            break;
          case 'video':
            u.video += f.bytes;
            vid += f.bytes;
            break;
          case 'voice':
            u.voice += f.bytes;
            voi += f.bytes;
            break;
        }
      }
      // Name 1:1 chats. A conversation id is "<uidA>_<uidB>"; the other uid is
      // the person. Falls back to a short label if the lookup fails.
      final me = ContactService();
      for (final u in byChat.values) {
        if (u.name.isNotEmpty) continue;
        final other = await _otherUid(u.id);
        if (other == null) {
          u.name = 'Chat';
          continue;
        }
        final real = await me.usernameFor(other);
        u.name = NicknameService.instance.display(other, real);
      }
      final list = byChat.values.toList()..sort((a, b) => b.total.compareTo(a.total));
      if (!mounted) return;
      setState(() {
        _image = img;
        _video = vid;
        _voice = voi;
        _chats = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _otherUid(String conversationId) async {
    final myUid = ContactService().currentUidOrNull;
    if (myUid == null) return null;
    final parts = conversationId.split('_');
    for (final p in parts) {
      if (p.isNotEmpty && p != myUid) return p;
    }
    return null;
  }

  Future<void> _clear({String? conversationId, required Set<String> types, required String what}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear $what?'),
        content: const Text(
          'The files are deleted from this phone to free space. The messages stay in the chat and show "unavailable" '
          'where the file was. This can\'t be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final freed = await LocalMessageStore.clearMedia(conversationId: conversationId, types: types);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Freed ${fmt(freed)}')));
    _scan();
  }

  void _chatSheet(_ChatUsage u) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('${u.name} · ${fmt(u.total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            for (final t in const ['image', 'video', 'voice'])
              ListTile(
                leading: Icon(_icons[t]),
                title: Text('Clear ${_labels[t]!.toLowerCase()}'),
                trailing: Text(fmt(t == 'image' ? u.image : (t == 'video' ? u.video : u.voice))),
                enabled: (t == 'image' ? u.image : (t == 'video' ? u.video : u.voice)) > 0,
                onTap: () {
                  Navigator.pop(ctx);
                  _clear(conversationId: u.id, types: {t}, what: '${_labels[t]!.toLowerCase()} in ${u.name}');
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_sweep_outlined, color: Theme.of(ctx).colorScheme.error),
              title: Text('Clear everything in this chat', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _clear(conversationId: u.id, types: {'image', 'video', 'voice'}, what: 'all media in ${u.name}');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _ruleTile(String kind) {
    final rule = _auto.ruleFor(kind);
    return ListTile(
      leading: Icon(_icons[kind]),
      title: Text(_labels[kind]!),
      subtitle: Text(_ruleText(rule)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final picked = await showModalBottomSheet<DownloadRule>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Download ${_labels[kind]!.toLowerCase()}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                for (final r in DownloadRule.values)
                  RadioListTile<DownloadRule>(
                    value: r,
                    groupValue: rule,
                    title: Text(_ruleTitle(r)),
                    subtitle: Text(_ruleText(r)),
                    onChanged: (v) => Navigator.pop(ctx, v),
                  ),
              ],
            ),
          ),
        );
        if (picked == null) return;
        await _auto.setRule(kind, picked);
        if (mounted) setState(() {});
      },
    );
  }

  static String _ruleTitle(DownloadRule r) {
    switch (r) {
      case DownloadRule.always:
        return 'Wi-Fi and mobile data';
      case DownloadRule.wifiOnly:
        return 'Wi-Fi only';
      case DownloadRule.never:
        return 'Never';
    }
  }

  static String _ruleText(DownloadRule r) {
    switch (r) {
      case DownloadRule.always:
        return 'Downloads by itself on any connection';
      case DownloadRule.wifiOnly:
        return 'Waits for Wi-Fi, then downloads by itself';
      case DownloadRule.never:
        return 'Tap the message to download';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _image + _video + _voice;
    return Scaffold(
      appBar: AppBar(title: const Text('Data and storage'), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Recount', onPressed: _scan),
      ]),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('AUTO-DOWNLOAD', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.6)),
          ),
          for (final k in AutoDownloadService.kinds) _ruleTile(k),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Media that isn\'t downloaded yet stays on the server for a short time. Tap it in the chat to download it.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('STORAGE', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.6)),
          ),
          if (_loading)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(fmt(total), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            ),
            for (final t in const ['image', 'video', 'voice'])
              ListTile(
                leading: Icon(_icons[t]),
                title: Text(_labels[t]!),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(4),
                    value: total == 0 ? 0 : (t == 'image' ? _image : (t == 'video' ? _video : _voice)) / total,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(fmt(t == 'image' ? _image : (t == 'video' ? _video : _voice))),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Clear ${_labels[t]!.toLowerCase()} everywhere',
                      onPressed: (t == 'image' ? _image : (t == 'video' ? _video : _voice)) == 0
                          ? null
                          : () => _clear(types: {t}, what: 'all ${_labels[t]!.toLowerCase()}'),
                    ),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('BY CHAT', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.6)),
            ),
            if (_chats.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No saved media', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            for (final u in _chats)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(u.name.isNotEmpty ? u.name[0].toUpperCase() : '?', style: TextStyle(color: scheme.onPrimaryContainer)),
                ),
                title: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  if (u.image > 0) 'Photos ${fmt(u.image)}',
                  if (u.video > 0) 'Videos ${fmt(u.video)}',
                  if (u.voice > 0) 'Voice ${fmt(u.voice)}',
                ].join(' · ')),
                trailing: Text(fmt(u.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => _chatSheet(u),
              ),
          ],
        ],
      ),
    );
  }
}
