import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/profile_photo_service.dart';
import '../../utils/photo_picker_flow.dart';

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
  bool _busyPhoto = false;
  String? _error;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _authService.currentUserProfile().then((doc) {
      if (mounted) setState(() => _photoUrl = doc.data()?['photoUrl'] as String?);
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Choose a picture -> crop / edit it -> press OK -> it becomes the
  /// profile photo. Nothing is uploaded until the person confirms in the
  /// editor.
  Future<void> _pickPhoto() async {
    final edited = await pickAndEditPhoto(context, label: 'Profile photo');
    if (edited == null || !mounted) return;

    setState(() => _busyPhoto = true);
    try {
      final ready = await prepareAvatarFile(edited);
      final url = await ProfilePhotoService.instance.setPhoto(ready);
      if (mounted) setState(() => _photoUrl = url);
      _snack('Profile photo updated');
    } catch (e) {
      _snack('Could not upload photo — check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
    }
  }

  Future<void> _removePhoto() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove profile photo?'),
        content: const Text('Your profile will go back to showing just your first letter, for everyone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyPhoto = true);
    try {
      await ProfilePhotoService.instance.removePhoto();
      if (mounted) setState(() => _photoUrl = null);
      _snack('Profile photo removed');
    } catch (e) {
      _snack('Could not remove the photo — check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
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
    final hasPhoto = _photoUrl != null && _photoUrl!.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(
          children: [
            Center(
              child: GestureDetector(
                onTap: _busyPhoto ? null : _pickPhoto,
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: scheme.primaryContainer,
                      foregroundImage: hasPhoto ? NetworkImage(_photoUrl!) : null,
                      onForegroundImageError: hasPhoto ? (_, __) {} : null,
                      child: Text(
                        _usernameController.text.isNotEmpty ? _usernameController.text[0].toUpperCase() : '?',
                        style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                      ),
                    ),
                    if (_busyPhoto)
                      const Positioned.fill(
                        child: CircleAvatar(
                          radius: 48,
                          backgroundColor: Colors.black45,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: scheme.primary,
                        child: Icon(Icons.camera_alt, size: 16, color: scheme.onPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: _busyPhoto ? null : _pickPhoto,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(hasPhoto ? 'Change photo' : 'Add photo'),
                ),
                if (hasPhoto)
                  TextButton.icon(
                    onPressed: _busyPhoto ? null : _removePhoto,
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
                  ),
              ],
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
