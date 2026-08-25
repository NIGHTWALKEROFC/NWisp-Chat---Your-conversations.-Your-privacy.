import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/contact_service.dart';
import '../../services/group_service.dart';
import '../../services/media_service.dart';
import '../contacts/find_users_screen.dart';
import 'group_chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _contactService = ContactService();
  final _nameController = TextEditingController();
  final Set<String> _selectedUids = {};
  File? _avatarFile;
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) setState(() => _avatarFile = File(picked.path));
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give the group a name first.')));
      return;
    }
    if (_selectedUids.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least 2 contacts — a group needs 3 people including you.')),
      );
      return;
    }
    setState(() => _creating = true);
    try {
      final groupId = GroupService.instance.newGroupId();
      String? avatarUrl;
      if (_avatarFile != null) {
        avatarUrl = await MediaService.uploadGroupAvatar(_avatarFile!, groupId);
      }
      await GroupService.instance.createGroup(
        groupId: groupId,
        name: name,
        avatarUrl: avatarUrl,
        memberUids: _selectedUids.toList(),
      );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't create the group: $e")));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _pickAvatar,
                  child: CircleAvatar(
                    radius: 32,
                    backgroundColor: scheme.primaryContainer,
                    backgroundImage: _avatarFile != null ? FileImage(_avatarFile!) : null,
                    child: _avatarFile == null ? const Icon(Icons.camera_alt_outlined) : null,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Group name', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Add members (${_selectedUids.length} selected)', style: Theme.of(context).textTheme.titleSmall),
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
                            'A group is built from your contacts — you don\'t have any yet.',
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
          );
      ),
    );
  }
}
