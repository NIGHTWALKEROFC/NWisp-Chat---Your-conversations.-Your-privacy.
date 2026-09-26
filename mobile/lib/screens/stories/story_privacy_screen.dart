import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/story_service.dart';
import '../../widgets/user_avatar.dart';

/// Feature: Stories — the audience picker. Used in two places with the
/// exact same UI: Settings > Privacy > "Story privacy" (editing the
/// app-wide default) and the story composer's "change for this post"
/// option (a one-off override). Either way this screen just returns the
/// chosen (mode, selectedUids) via [Navigator.pop] — it never decides on
/// its own what to do with the choice; the caller does (see
/// [isGlobalDefault] below).
class StoryPrivacyScreen extends StatefulWidget {
  final String initialMode;
  final List<String> initialSelectedUids;
  /// When true, "Save" also writes the choice as the app-wide default
  /// (StoryService.setGlobalPrivacyDefault) before popping. When false
  /// (a per-post override from the composer), it only pops the result —
  /// the composer decides what to do with it, and nothing is saved as a
  /// standing default.
  final bool isGlobalDefault;

  const StoryPrivacyScreen({
    super.key,
    required this.initialMode,
    this.initialSelectedUids = const [],
    required this.isGlobalDefault,
  });

  @override
  State<StoryPrivacyScreen> createState() => _StoryPrivacyScreenState();
}

class _StoryPrivacyScreenState extends State<StoryPrivacyScreen> {
  final _storyService = StoryService.instance;
  late String _mode = widget.initialMode;
  late Set<String> _selected = widget.initialSelectedUids.toSet();
  List<String>? _contactUids;
  final Map<String, String> _usernameCache = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final uids = await _storyService.myContactUids();
    if (mounted) setState(() => _contactUids = uids);
  }

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    if (widget.isGlobalDefault) {
      await _storyService.setGlobalPrivacyDefault(_mode, _selected.toList());
    }
    if (mounted) Navigator.of(context).pop((_mode, _selected.toList()));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Story privacy'),
        actions: [
          TextButton(
            onPressed: _saving || (_mode == 'selected' && _selected.isEmpty) ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        children: [
          RadioListTile<String>(
            value: 'contacts',
            groupValue: _mode,
            title: const Text('All my contacts'),
            subtitle: const Text('Everyone you have an existing chat with'),
            onChanged: (v) => setState(() => _mode = v!),
          ),
          RadioListTile<String>(
            value: 'selected',
            groupValue: _mode,
            title: const Text('Only these people'),
            subtitle: const Text('Choose specific people below'),
            onChanged: (v) => setState(() => _mode = v!),
          ),
          if (_mode == 'selected') ...[
            const Divider(height: 24),
            if (_contactUids == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_contactUids!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "You don't have any contacts yet — start a chat with someone first.",
                  style: TextStyle(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              )
            else
              for (final uid in _contactUids!)
                FutureBuilder<String>(
                  future: _usernameFor(uid),
                  builder: (context, snap) {
                    final name = snap.data ?? '...';
                    final checked = _selected.contains(uid);
                    return CheckboxListTile(
                      secondary: UserAvatar(uid: uid, name: name, radius: 18),
                      title: Text(name),
                      value: checked,
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(uid);
                        } else {
                          _selected.remove(uid);
                        }
                      }),
                    );
                  },
                ),
          ],
        ],
      ),
    );
  }
}
