import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/contact_service.dart';

class FindUsersScreen extends StatefulWidget {
  const FindUsersScreen({super.key});
  @override
  State<FindUsersScreen> createState() => _FindUsersScreenState();
}

class _FindUsersScreenState extends State<FindUsersScreen> {
  final _contactService = ContactService();
  final _authService = AuthService();
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  final Set<String> _sentTo = {};
  bool _loading = false;

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    final results = await _contactService.searchUsers(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  Future<void> _sendRequest(String uid, String username) async {
    final myProfile = await _authService.currentUserProfile();
    final myUsername = (myProfile.data()?['username'] as String?) ?? '';
    try {
      await _contactService.sendRequest(toUid: uid, toUsername: username, myUsername: myUsername);
      if (!mounted) return;
      setState(() => _sentTo.add(uid));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search by username',
            border: InputBorder.none,
          ),
          onChanged: (value) {
            if (value.trim().length >= 2) _search(value);
          },
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final user = _results[i];
                final uid = user['uid'] as String;
                final username = (user['username'] as String?) ?? '';
                final alreadySent = _sentTo.contains(uid);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                  ),
                  title: Text(username),
                  trailing: alreadySent
                      ? const Text('Sent')
                      : TextButton(
                          onPressed: () => _sendRequest(uid, username),
                          child: const Text('Add'),
                        ),
                );
              },
            ),
    );
  }
}
