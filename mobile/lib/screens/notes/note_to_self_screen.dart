import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/local_message.dart';
import '../../services/note_to_self_service.dart';
import '../../services/private_keyboard_service.dart';
import '../../services/screenshot_guard_service.dart';

/// Feature: "Note to self" — a private notepad shaped like a chat.
///
/// Everything here is stored only on this phone, encrypted (see
/// NoteToSelfService). Add a note, tap-and-hold one to copy / edit / delete
/// it, or clear them all from the 3-dot menu.
class NoteToSelfScreen extends StatefulWidget {
  const NoteToSelfScreen({super.key});

  @override
  State<NoteToSelfScreen> createState() => _NoteToSelfScreenState();
}

class _NoteToSelfScreenState extends State<NoteToSelfScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  LocalMessage? _editing;
  int _lastCount = -1;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Private notes must not end up in a screenshot or the recents preview.
    ScreenshotGuardService.acquire();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    ScreenshotGuardService.release();
    super.dispose();
  }

  bool get _canSave => _controller.text.trim().isNotEmpty && !_saving;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final text = _controller.text;
    final editing = _editing;
    try {
      if (editing != null) {
        await NoteToSelfService.edit(editing.id, text);
      } else {
        await NoteToSelfService.add(text);
      }
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _editing = null;
        _saving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save that note.")));
    }
  }

  void _startEdit(LocalMessage note) {
    setState(() => _editing = note);
    _controller.text = note.text;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _controller.clear();
  }

  Future<void> _confirmDelete(LocalMessage note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text('It will be permanently removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (_editing?.id == note.id) _cancelEdit();
    await NoteToSelfService.delete([note.id]);
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('Delete all notes?'),
        content: const Text('Every note to yourself will be permanently removed from this phone. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (ok != true) return;
    _cancelEdit();
    await NoteToSelfService.clearAll();
  }

  void _showActions(LocalMessage note) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: note.text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(sheetContext);
                _startEdit(note);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDelete(note);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- formatting ------------------------------------------------------

  String _dayLabel(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${months[t.month - 1]} ${t.day}${t.year == now.year ? '' : ', ${t.year}'}';
  }

  String _time(DateTime t) {
    final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$hour12:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  // ---- UI --------------------------------------------------------------

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_note, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Your private notepad', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              'Jot down anything you want to keep. Notes are saved only on this phone, encrypted — '
              'never sent to anyone, never uploaded.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNote(LocalMessage note, ColorScheme scheme) {
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => _showActions(note),
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(note.text, style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 15.5)),
              ),
              const SizedBox(height: 4),
              Text(
                '${note.editedAt != null ? 'edited · ' : ''}${_time(note.createdAt)}',
                style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer.withValues(alpha: 0.65)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Note to self'),
            Text(
              'Only on this phone · never sent',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') _confirmClearAll();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'clear', child: Text('Delete all notes')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<LocalMessage>>(
              stream: NoteToSelfService.watch(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final notes = snapshot.data!;
                if (notes.isEmpty) return _buildEmpty(scheme);

                // Keep the newest note in view when one is added.
                if (notes.length != _lastCount) {
                  final grew = _lastCount >= 0 && notes.length > _lastCount;
                  _lastCount = notes.length;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!_scroll.hasClients) return;
                    if (grew || _scroll.position.pixels == 0) {
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    }
                  });
                }

                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: notes.length,
                  itemBuilder: (context, i) {
                    final note = notes[i];
                    final showDay = i == 0 || !_sameDay(notes[i - 1].createdAt, note.createdAt);
                    return Column(
                      children: [
                        if (showDay)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(_dayLabel(note.createdAt), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                            ),
                          ),
                        _buildNote(note, scheme),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          if (_editing != null)
            Material(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Editing note', style: TextStyle(color: scheme.onSecondaryContainer))),
                    IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Cancel edit', onPressed: _cancelEdit),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        // Private keyboard mode (off by default) applies here too.
                        enableSuggestions: !PrivateKeyboardService.enabled.value,
                        autocorrect: !PrivateKeyboardService.enabled.value,
                        enableIMEPersonalizedLearning: !PrivateKeyboardService.enabled.value,
                        decoration: const InputDecoration(
                          hintText: 'Write a note',
                          border: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _canSave ? scheme.primary : scheme.surfaceContainerHighest),
                    child: IconButton(
                      onPressed: _canSave ? _save : null,
                      icon: Icon(
                        _editing != null ? Icons.check_rounded : Icons.arrow_upward_rounded,
                        color: _canSave ? scheme.onPrimary : scheme.onSurfaceVariant,
                      ),
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
