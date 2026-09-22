import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/community_service.dart';
import '../../services/group_service.dart';
import '../../services/media_service.dart';
import '../../utils/photo_picker_flow.dart';
import '../../widgets/location_fields.dart';

/// Create a public community — or, when [editing] is given, change one
/// you administer. Everything except the name is optional.
class CreateCommunityScreen extends StatefulWidget {
  final CommunityListing? editing;
  const CreateCommunityScreen({super.key, this.editing});

  @override
  State<CreateCommunityScreen> createState() => _CreateCommunityScreenState();
}

class _CreateCommunityScreenState extends State<CreateCommunityScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late final _description = TextEditingController(text: widget.editing?.description ?? '');
  late final _rules = TextEditingController(text: widget.editing?.rules ?? '');
  late String? _category = widget.editing?.category;
  late CommunityLocation _location = widget.editing?.location ?? const CommunityLocation();
  late bool _onlyAdmins = widget.editing?.onlyAdminsCanSend ?? false;
  late int _maxMembers = widget.editing?.maxMembers ?? CommunityService.defaultMaxMembers;
  File? _avatar;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.editing != null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _rules.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final file = await pickAndEditPhoto(context, label: 'Community photo');
    if (file != null && mounted) setState(() => _avatar = file);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.length < 3) {
      setState(() => _error = 'Give your community a name (at least 3 characters).');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final prepared = _avatar == null ? null : await prepareAvatarFile(_avatar!);
      if (!_isEdit) {
        final id = await CommunityService.instance.create(
          name: name,
          description: _description.text,
          category: _category,
          rules: _rules.text,
          location: _location,
          avatarFile: prepared,
          onlyAdminsCanSend: _onlyAdmins,
          maxMembers: _maxMembers,
        );
        if (!mounted) return;
        Navigator.pop(context, id);
      } else {
        final id = widget.editing!.id;
        await CommunityService.instance.update(
          groupId: id,
          name: name,
          description: _description.text,
          category: _category,
          rules: _rules.text,
          location: _location,
          onlyAdminsCanSend: _onlyAdmins,
          maxMembers: _maxMembers,
        );
        if (prepared != null) {
          final base = await MediaService.uploadGroupAvatar(prepared, id);
          await GroupService.instance.updateAvatar(id, '$base?v=${DateTime.now().millisecondsSinceEpoch}');
        }
        if (!mounted) return;
        Navigator.pop(context, id);
      }
    } catch (e) {
      if (!mounted) return;
      final denied = e.toString().contains('permission-denied');
      setState(() {
        _saving = false;
        _error = denied
            ? "The database refused this. If you just installed this update, publish the new Firestore rules first (see the setup notes)."
            : 'Could not save — check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final existingUrl = widget.editing?.avatarUrl;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit community' : 'New community')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: GestureDetector(
              onTap: _saving ? null : _pickPhoto,
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: scheme.primaryContainer,
                    foregroundImage: _avatar != null
                        ? FileImage(_avatar!)
                        : (existingUrl != null && existingUrl.isNotEmpty ? NetworkImage(existingUrl) as ImageProvider : null),
                    child: Icon(Icons.groups_rounded, size: 40, color: scheme.onPrimaryContainer),
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
          const SizedBox(height: 4),
          Center(child: Text('Community photo (optional)', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant))),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Community name', prefixIcon: Icon(Icons.groups_outlined)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            maxLength: 300,
            maxLines: 3,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What is this community about? (optional)',
              alignLabelWithHint: true,
              prefixIcon: Icon(Icons.info_outline),
            ),
          ),
          const SizedBox(height: 16),
          Text('Topic (optional)', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final c in kCommunityCategories)
                ChoiceChip(
                  label: Text(c),
                  selected: _category == c,
                  onSelected: (sel) => setState(() => _category = sel ? c : null),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Location (optional)', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
          const SizedBox(height: 4),
          Text(
            'Helps people nearby find your community. Fill in as much or as little as you like — or leave it empty to keep it open to everyone.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          LocationFields(value: _location, onChanged: (v) => setState(() => _location = v)),
          const SizedBox(height: 8),
          TextField(
            controller: _rules,
            maxLength: 500,
            maxLines: 4,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Community rules (optional)',
              alignLabelWithHint: true,
              prefixIcon: Icon(Icons.rule_folder_outlined),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.campaign_outlined),
            title: const Text('Announcements only'),
            subtitle: const Text('Only admins can post. Members can still read, react and reply privately.'),
            value: _onlyAdmins,
            onChanged: (v) => setState(() => _onlyAdmins = v),
          ),
          const SizedBox(height: 8),
          Text('Maximum members', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [for (final n in CommunityService.maxMembersOptions) ButtonSegment<int>(value: n, label: Text('$n'))],
            selected: {_maxMembers},
            onSelectionChanged: (s) => setState(() => _maxMembers = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            'Every message is encrypted separately for each member, so communities stay small on purpose.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Anyone using NWisp can find and join this community, and members can see each other\'s usernames. '
                    'Messages are never stored on a server — they are saved only on members\' phones.',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                : Text(_isEdit ? 'Save changes' : 'Create community'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
