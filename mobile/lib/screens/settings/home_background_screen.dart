import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/chat_wallpaper_service.dart';
import '../../services/home_background_service.dart';

/// Feature: home screen background. Mirrors ChatWallpaperScreen's own
/// wallpaper grid (same presets, same custom-photo tile) but with no
/// accent/bubble-colour section — that concept only makes sense inside one
/// chat's message bubbles, not the chat LIST itself.
class HomeBackgroundScreen extends StatefulWidget {
  const HomeBackgroundScreen({super.key});
  @override
  State<HomeBackgroundScreen> createState() => _HomeBackgroundScreenState();
}

class _HomeBackgroundScreenState extends State<HomeBackgroundScreen> {
  String _wallpaperId = 'default';
  String? _customImagePath;
  bool _pickingPhoto = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = await HomeBackgroundService.getBackground();
    if (!mounted) return;
    setState(() {
      _wallpaperId = w.id;
      _customImagePath = w.imagePath;
    });
  }

  Future<void> _pick(ChatWallpaper w) async {
    await HomeBackgroundService.setBackground(w.id);
    if (mounted) setState(() => _wallpaperId = w.id);
  }

  Future<void> _pickCustomPhoto() async {
    setState(() => _pickingPhoto = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (picked == null) return;
      final path = await HomeBackgroundService.persistCustomImage(File(picked.path));
      await HomeBackgroundService.setCustomBackground(path);
      if (!mounted) return;
      setState(() {
        _wallpaperId = 'custom';
        _customImagePath = path;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't set that photo: $e")));
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Home screen background')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.72),
          itemCount: kChatWallpapers.length + 1,
          itemBuilder: (context, i) {
            if (i == kChatWallpapers.length) {
              final selected = _wallpaperId == 'custom' && _customImagePath != null;
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _pickingPhoto ? null : _pickCustomPhoto,
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                          border: selected ? Border.all(color: scheme.primary, width: 3) : Border.all(color: scheme.outlineVariant),
                          image: selected ? DecorationImage(image: FileImage(File(_customImagePath!)), fit: BoxFit.cover) : null,
                        ),
                        child: _pickingPhoto
                            ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                            : (selected
                                ? const Icon(Icons.check_circle, color: Colors.white)
                                : Icon(Icons.add_photo_alternate_outlined, color: scheme.onSurfaceVariant)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text('Custom photo', style: TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              );
            }
            final w = kChatWallpapers[i];
            final selected = w.id == _wallpaperId;
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _pick(w),
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: w.colors.isEmpty ? scheme.surfaceContainerHighest : (w.colors.length == 1 ? w.colors.first : null),
                        gradient: w.colors.length > 1 ? LinearGradient(colors: w.colors, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
                        borderRadius: BorderRadius.circular(12),
                        border: selected ? Border.all(color: scheme.primary, width: 3) : Border.all(color: scheme.outlineVariant),
                      ),
                      child: selected ? Icon(Icons.check_circle, color: w.colors.isEmpty || !isDarkWallpaper(w) ? scheme.primary : Colors.white) : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(w.name, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
