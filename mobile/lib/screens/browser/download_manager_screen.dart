import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../../services/browser_download_service.dart';

/// Feature: Download manager — everything saved from the private browser:
/// running downloads with progress and a cancel button, finished ones with
/// size, time and the folder, and a way to open/share or delete each one.
class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  final _svc = BrowserDownloadService.instance;

  @override
  void initState() {
    super.initState();
    _svc.loadRecords();
  }

  static String _size(int? b) {
    if (b == null) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  IconData _icon(String kind) {
    switch (kind) {
      case 'video':
        return Icons.videocam_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'image':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  String? _fullPath(DownloadRecord r) {
    final dir = r.savedTo;
    if (dir == null || dir == 'Gallery') return null;
    return p.join(dir, r.name);
  }

  Future<void> _shareOrOpen(DownloadRecord r) async {
    final path = _fullPath(r);
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This one was saved to your gallery — open it there.')));
      return;
    }
    if (!await File(path).exists()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The file is no longer there.')));
      return;
    }
    await Share.shareXFiles([XFile(path)]);
  }

  Future<void> _delete(DownloadRecord r, {required bool withFile}) async {
    if (withFile) {
      final path = _fullPath(r);
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await _svc.remove(r.id);
  }

  void _menu(DownloadRecord r) {
    final canFile = _fullPath(r) != null;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (r.status == 'done')
              ListTile(
                leading: const Icon(Icons.ios_share_rounded),
                title: Text(canFile ? 'Open / share' : 'Saved in your gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareOrOpen(r);
                },
              ),
            if (r.status == 'done' && r.savedTo != null)
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Show folder'),
                subtitle: Text(r.savedTo!),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: r.savedTo!));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Folder path copied')));
                },
              ),
            if (r.url.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Copy link'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: r.url));
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Remove from list'),
              onTap: () {
                Navigator.pop(ctx);
                _delete(r, withFile: false);
              },
            ),
            if (canFile && r.status == 'done')
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text('Delete file', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  _delete(r, withFile: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            tooltip: 'Clear finished',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _svc.clearFinished(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<DownloadRecord>>(
        valueListenable: _svc.records,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download_done_rounded, size: 60, color: scheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    const Text('No downloads yet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                      'Open a page in the private browser and choose "Download from this page" in the ⋮ menu.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final r = list[i];
              final running = r.status == 'downloading';
              final subtitle = <String>[
                if (running) (r.progress == null ? 'Downloading…' : 'Downloading ${(r.progress! * 100).toStringAsFixed(0)}%'),
                if (r.status == 'done') 'Saved · ${_size(r.bytes)}'.replaceAll(RegExp(r' · $'), ''),
                if (r.status == 'failed') 'Failed${r.error != null ? ' — ${r.error}' : ''}',
                if (r.status == 'cancelled') 'Cancelled',
                _when(r.startedAt),
              ];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(_icon(r.kind), color: scheme.onPrimaryContainer),
                ),
                title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subtitle.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (running)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(value: r.progress),
                      ),
                    if (r.status == 'done' && r.savedTo != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(r.savedTo!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
                isThreeLine: running || (r.status == 'done' && r.savedTo != null),
                trailing: running
                    ? IconButton(icon: const Icon(Icons.close), tooltip: 'Cancel', onPressed: () => _svc.cancel(r.id))
                    : IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _menu(r)),
                onTap: running ? null : () => _menu(r),
              );
            },
          );
        },
      ),
    );
  }
}
