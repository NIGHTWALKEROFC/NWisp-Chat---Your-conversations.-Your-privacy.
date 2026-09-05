import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/moderation_service.dart';

/// Replaces the old one-tap "report" action in ChatSettingsScreen. Lets
/// the reporter pick WHICH specific rule was broken (not just a generic
/// reason), add optional details, and optionally attach a photo as
/// proof — see ModerationService.reportUser for what happens to all of
/// this (including why the reporter's email is attached automatically).
class ReportUserScreen extends StatefulWidget {
  final String reportedUid;
  final String reportedLabel;
  const ReportUserScreen({super.key, required this.reportedUid, required this.reportedLabel});

  @override
  State<ReportUserScreen> createState() => _ReportUserScreenState();
}

class _ReportUserScreenState extends State<ReportUserScreen> {
  final _moderationService = ModerationService();
  final _detailsController = TextEditingController();
  String? _selectedRule;
  File? _proofFile;
  bool _submitting = false;

  @override
  void dispose() {
    _detailsController.dispose();
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
    if (_selectedRule == null) return;
    setState(() => _submitting = true);
    try {
      await _moderationService.reportUser(
        reportedUid: widget.reportedUid,
        ruleViolated: _selectedRule!,
        details: _detailsController.text.trim().isEmpty ? null : _detailsController.text.trim(),
        proofFile: _proofFile,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit the report. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Report ${widget.reportedLabel}')),
      body: AbsorbPointer(
        absorbing: _submitting,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('What rule did this break?', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            ...reportableRules.map(
              (rule) => RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                title: Text(rule),
                value: rule,
                groupValue: _selectedRule,
                onChanged: (v) => setState(() => _selectedRule = v),
              ),
            ),
            const SizedBox(height: 16),
            Text('Add any details (optional)', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _detailsController,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Anything that would help us understand what happened',
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
              'Your email is included with this report so we can follow up with you about the '
              "outcome — it's never shown to the person you're reporting.",
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_selectedRule == null || _submitting) ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Submit report'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
