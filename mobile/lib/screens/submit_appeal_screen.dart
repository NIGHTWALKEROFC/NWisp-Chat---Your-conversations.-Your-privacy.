import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/moderation_service.dart';

/// Reached from SuspendedAccountScreen's "Appeal" button. Submits to the
/// `appeals` collection — see ModerationService.submitAppeal for what
/// happens to it (review is manual, via the Firebase console; see
/// MODERATION_GUIDE.md).
class SubmitAppealScreen extends StatefulWidget {
  const SubmitAppealScreen({super.key});

  @override
  State<SubmitAppealScreen> createState() => _SubmitAppealScreenState();
}

class _SubmitAppealScreenState extends State<SubmitAppealScreen> {
  final _moderationService = ModerationService();
  final _textController = TextEditingController();
  File? _proofFile;
  bool _submitting = false;
  bool _submitted = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _attachProof() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    setState(() => _proofFile = File(picked.path));
  }

  Future<void> _submit() async {
    if (_textController.text.trim().isEmpty) return;
    setState(() => _submitting = true);
    try {
      await _moderationService.submitAppeal(text: _textController.text.trim(), proofFile: _proofFile);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitted = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not submit your appeal: $e'), duration: const Duration(seconds: 8)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_submitted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Appeal submitted')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mark_email_read_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                const Text(
                  "Your appeal has been submitted. We'll email you the outcome once it's been reviewed.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Submit an appeal')),
      body: AbsorbPointer(
        absorbing: _submitting,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Explain why you believe this suspension was a mistake. Be as specific as you can — '
              'this is reviewed by a real person, not automatically.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Your appeal',
              ),
            ),
            const SizedBox(height: 16),
            Text('Attach proof (optional)', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_proofFile != null)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(_proofFile!, height: 160, width: double.infinity, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      icon: const CircleAvatar(child: Icon(Icons.close, size: 18)),
                      onPressed: () => setState(() => _proofFile = null),
                    ),
                  ),
                ],
              )
            else
              OutlinedButton.icon(
                onPressed: _attachProof,
                icon: const Icon(Icons.attach_file),
                label: const Text('Attach a photo'),
              ),
            const SizedBox(height: 8),
            Text(
              'Your email is included with this appeal so we can follow up with you about the outcome.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_textController.text.trim().isEmpty || _submitting) ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Submit appeal'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
