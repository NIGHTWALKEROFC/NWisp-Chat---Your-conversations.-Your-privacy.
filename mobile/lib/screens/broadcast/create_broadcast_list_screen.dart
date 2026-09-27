import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/broadcast_list_service.dart';
import '../../services/contact_service.dart';
import '../contacts/find_users_screen.dart';
import 'broadcast_list_screen.dart';

/// Feature: broadcast lists — "New broadcast list" / "Edit recipients".
/// Deliberately modeled on CreateGroupScreen's own contact-picker (same
/// CheckboxListTile-over-contactsStream pattern), but simpler: no avatar,
/// no announcement-only toggle, and only 1 member is required (a broadcast
/// list of one is just "a saved shortcut to message this person" — still
/// useful, unlike a group, which genuinely needs the extra people).
class CreateBroadcastListScreen extends StatefulWidget {
  /// Pass an existing list to rename/change its members instead of
  /// creating a new one.
  final BroadcastList? existing;

  const CreateBroadcastListScreen({super.key, this.existing});

  @override
  State<CreateBroadcastListScreen> createState() => _CreateBroadcastListScreenState();
}

class _CreateBroadcastListScreenState extends State<CreateBroadcastListScreen> {
  final _contactService = ContactService();
  late final _nameController = TextEditingController(text: widget.existing?.name ?? '');
  late final Set<String> _selectedUids = Set<String>.from(widget.existing?.memberUids ?? const []);
  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give the list a name first.')));
      return;
    }
    if (_selectedUids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick at least 1 contact.')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEditing) {
        await BroadcastListService.renameList(widget.existing!.id, name);
        await BroadcastListService.setMembers(widget.existing!.id, _selectedUids.toList());
        if (!mounted) return;
        Navigator.pop(context);
      } else {
        final list = await BroadcastListService.createList(name, _selectedUids.toList());
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => BroadcastListScreen(listId: list.id)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit recipients' : 'New broadcast list'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isEditing ? 'Save' : 'Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'List name', border: OutlineInputBorder()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Recipients (${_selectedUids.length} selected)', style: Theme.of(context).textTheme.titleSmall),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Each person gets a normal message from you — they won't see this list or who else is on it.",
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _contactService.contactsStream(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "A broadcast list is built from your contacts — you don't have any yet.",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FindUsersScreen())),
                            icon: const Icon(Icons.search),
                            label: const Text('Find people by username'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final uid = docs[i].id;
                    final username = (docs[i].data()['username'] as String?) ?? 'Unknown';
                    final selected = _selectedUids.contains(uid);
                    return CheckboxListTile(
                      value: selected,
                      title: Text(username),
                      secondary: CircleAvatar(child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?')),
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedUids.add(uid);
                          } else {
                            _selectedUids.remove(uid);
                          }
                        });
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
