import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/auth_service.dart';
import '../../services/media_service.dart';

class EditProfileScreen extends StatefulWidget {
  final String currentUsername;
  const EditProfileScreen({super.key, required this.currentUsername});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _usernameController = TextEditingController(text: widget.currentUsername);
  final _authService = AuthService();
  bool _saving = false;
  bool _uploadingPhoto = false;
  String? _error;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _authService.currentUserProfile().then((doc) {
      if (mounted) setState(() => _photoUrl = doc.data()?['photoUrl'] as String?);
    });
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
    if (picked == null) return;

    setState(() => _uploadingPhoto = true);
    try {
      final uid = _authService.currentUserId!;
      final url = await MediaService.uploadAvatar(File(picked.path), uid);
      await _authService.updatePhotoUrl(url);
      if (mounted) setState(() => _photoUrl = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not upload photo — check your connection and try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _save() async {
    final newUsername = _usernameController.text.trim();
    if (newUsername.isEmpty) {
      setState(() => _error = 'Username cannot be empty');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _authService.updateUsername(newUsername);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated')),
      );
      Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString().contains('taken') ? 'That username is taken.' : 'Could not update profile.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: scheme.primaryContainer,
                    backgroundImage: _photoUrl != null ? NetworkImage(_photoUrl!) : null,
                    child: _photoUrl == null
                        ? Text(
                            _usernameController.text.isNotEmpty ? _usernameController.text[0].toUpperCase() : '?',
                            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                          )
                        : null,
                  ),
                  if (_uploadingPhoto)
                    Positioned.fill(
                      child: CircleAvatar(
                        radius: 40,
                        backgroundColor: Colors.black45,
                        child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: _uploadingPhoto ? null : _pickPhoto,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: const Text('Change photo'),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person_outline),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
