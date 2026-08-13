import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/branding_service.dart';
import '../../services/media_service.dart';
import '../../services/theme_service.dart';

const _accentPresets = [
  Color(0xFF00C896),
  Color(0xFF6750A4),
  Color(0xFF1E88E5),
  Color(0xFFEF6C00),
  Color(0xFFD81B60),
  Color(0xFF2E7D32),
  Color(0xFF00838F),
  Color(0xFFC62828),
  Color(0xFF8D6E63),
  Color(0xFF5E35B1),
];

class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});
  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  bool _uploadingLogo = false;

  Future<void> _pickLogo(BrandingService branding) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
    if (picked == null) return;

    setState(() => _uploadingLogo = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final url = await MediaService.uploadAvatar(File(picked.path), '${uid}_logo');
      await branding.setLogoUrl(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not upload logo — check your connection and try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  void _openCustomColorPicker(BrandingService branding) {
    var color = branding.accentColor ?? _accentPresets.first;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final hsv = HSVColor.fromColor(color);
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 8,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Custom color', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 60, child: Text('Hue')),
                    Expanded(
                      child: Slider(
                        value: hsv.hue,
                        min: 0,
                        max: 360,
                        onChanged: (v) => setSheetState(() => color = hsv.withHue(v).toColor()),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 60, child: Text('Saturation')),
                    Expanded(
                      child: Slider(
                        value: hsv.saturation,
                        onChanged: (v) => setSheetState(() => color = hsv.withSaturation(v).toColor()),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 60, child: Text('Brightness')),
                    Expanded(
                      child: Slider(
                        value: hsv.value,
                        onChanged: (v) => setSheetState(() => color = hsv.withValue(v).toColor()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    branding.setAccentColor(color);
                    Navigator.pop(sheetContext);
                  },
                  child: const Text('Apply color'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeService = context.watch<ThemeService>();
    final branding = context.watch<BrandingService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('This device only', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            'Theme mode, accent color, and logo below apply just to your phone — the app name stays the same for everyone.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Text('Theme mode', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {themeService.mode},
            onSelectionChanged: (s) => themeService.setMode(s.first),
          ),
          const SizedBox(height: 28),
          Text('Accent color', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final color in _accentPresets)
                GestureDetector(
                  onTap: () => branding.setAccentColor(color),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: branding.accentColor == color
                          ? Border.all(color: scheme.onSurface, width: 3)
                          : null,
                    ),
                  ),
                ),
              GestureDetector(
                onTap: () => _openCustomColorPicker(branding),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const SweepGradient(
                      colors: [
                        Colors.red,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Colors.purple,
                        Colors.red,
                      ],
                    ),
                  ),
                  child: const Icon(Icons.colorize, size: 18, color: Colors.white),
                ),
              ),
              GestureDetector(
                onTap: () => branding.setAccentColor(null),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.outline),
                  ),
                  child: Icon(Icons.refresh, size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('App logo', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Replaces the icon shown on your login screen and settings header with your own image. '
            'This does NOT change the home-screen app icon — that always needs a new app build/release '
            'and cannot be swapped at runtime on Android or iOS.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: scheme.surfaceContainerHigh,
                backgroundImage: branding.logoUrl != null ? NetworkImage(branding.logoUrl!) : null,
                child: branding.logoUrl == null ? Icon(Icons.lock_outline_rounded, color: scheme.primary) : null,
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: _uploadingLogo ? null : () => _pickLogo(branding),
                icon: _uploadingLogo
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_outlined, size: 18),
                label: Text(_uploadingLogo ? 'Uploading…' : 'Choose image'),
              ),
              if (branding.logoUrl != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => branding.setLogoUrl(null),
                  child: const Text('Reset to default'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
