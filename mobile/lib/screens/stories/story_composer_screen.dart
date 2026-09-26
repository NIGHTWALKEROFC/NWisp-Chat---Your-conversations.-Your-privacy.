import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/story_service.dart';
import 'story_privacy_screen.dart';

/// Feature: Stories — the composer. Reached from the "+" on the Stories
/// tab. Picks a photo or video, lets the person add a caption, shows
/// their current privacy default with a one-tap way to override it for
/// just this post, and posts (compress -> encrypt -> upload -> create the
/// Firestore doc — see StoryService.postStory for the full pipeline).
class StoryComposerScreen extends StatefulWidget {
  const StoryComposerScreen({super.key});

  @override
  State<StoryComposerScreen> createState() => _StoryComposerScreenState();
}

class _StoryComposerScreenState extends State<StoryComposerScreen> {
  final _storyService = StoryService.instance;
  final _captionController = TextEditingController();

  File? _mediaFile;
  String? _mediaType; // 'image' or 'video'
  String _privacyMode = 'contacts';
  List<String> _privacySelectedUids = const [];
  bool _privacyLoaded = false;
  bool _posting = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDefaultPrivacy();
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _loadDefaultPrivacy() async {
    final (mode, selected) = await _storyService.getGlobalPrivacyDefault();
    if (mounted) {
      setState(() {
        _privacyMode = mode;
        _privacySelectedUids = selected;
        _privacyLoaded = true;
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 100);
    if (picked != null) {
      setState(() {
        _mediaFile = File(picked.path);
        _mediaType = 'image';
      });
    }
  }

  Future<void> _pickVideo(ImageSource source) async {
    final picked = await ImagePicker().pickVideo(source: source, maxDuration: const Duration(seconds: 60));
    if (picked != null) {
      setState(() {
        _mediaFile = File(picked.path);
        _mediaType = 'video';
      });
    }
  }

  void _showPickerSheet() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Record a video'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickVideo(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Choose a photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose a video'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickVideo(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changePrivacyForThisPost() async {
    final result = await Navigator.push<(String, List<String>)>(
      context,
      MaterialPageRoute(
        builder: (_) => StoryPrivacyScreen(
          initialMode: _privacyMode,
          initialSelectedUids: _privacySelectedUids,
          isGlobalDefault: false,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _privacyMode = result.$1;
        _privacySelectedUids = result.$2;
      });
    }
  }

  Future<void> _post() async {
    if (_mediaFile == null || _mediaType == null) return;
    setState(() {
      _posting = true;
      _error = null;
      _progress = 0;
    });
    try {
      await _storyService.postStory(
        mediaFile: _mediaFile!,
        mediaType: _mediaType!,
        caption: _captionController.text,
        privacyMode: _privacyMode,
        selectedUids: _privacySelectedUids,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _posting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  String get _privacyLabel {
    if (_privacyMode == 'selected') {
      final n = _privacySelectedUids.length;
      return 'Only $n ${n == 1 ? 'person' : 'people'}';
    }
    return 'All my contacts';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New story'),
        actions: [
          if (_mediaFile != null)
            TextButton(
              onPressed: _posting || !_privacyLoaded ? null : _post,
              child: const Text('Share'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _mediaFile == null
                  ? Center(
                      child: OutlinedButton.icon(
                        onPressed: _showPickerSheet,
                        icon: const Icon(Icons.add_a_photo_outlined),
                        label: const Text('Choose photo or video'),
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_mediaType == 'image')
                          Image.file(_mediaFile!, fit: BoxFit.contain)
                        else
                          Container(
                            color: Colors.black,
                            child: const Center(
                              child: Icon(Icons.play_circle_outline, size: 64, color: Colors.white70),
                            ),
                          ),
                        if (_posting)
                          Container(
                            color: Colors.black45,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(value: _progress > 0 ? _progress : null, color: Colors.white),
                                  const SizedBox(height: 12),
                                  const Text('Posting...', style: TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            if (_mediaFile != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _captionController,
                  enabled: !_posting,
                  decoration: const InputDecoration(hintText: 'Add a caption (optional)'),
                  maxLength: 200,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('Who can see this'),
                subtitle: Text(_privacyLoaded ? _privacyLabel : 'Loading...'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _posting || !_privacyLoaded ? null : _changePrivacyForThisPost,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
