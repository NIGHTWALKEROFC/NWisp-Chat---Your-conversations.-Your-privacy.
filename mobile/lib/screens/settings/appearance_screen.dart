import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/branding_service.dart';
import '../../services/media_service.dart';
import '../../services/theme_service.dart';

const _accentPresets = [
  Color(0xFF00C896), // default teal-green
  Color(0xFF6750A4), // purple
  Color(0xFF1E88E5), // blue
  Color(0xFFEF6C00), // orange
  Color(0xFFD81B60), // pink
  Color(0xFF2E7D32), // green
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
      // Reuses the same public "avatars" bucket set up for profile photos —
      // no extra Supabase configuration needed beyond what avatar upload
      // already requires.
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
            'Shown on your login screen and settings header. This does NOT change '
            'the home-screen app icon — that needs a new app build.',
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
                  child: const Text('Reset'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
