import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/branding_service.dart';
import '../../services/theme_service.dart';
import 'home_background_screen.dart';

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
  // Feature: more theme options — additional curated accent colors, on
  // top of the 10 already here plus the full custom color picker below.
  Color(0xFF00BFA5),
  Color(0xFFFFB300),
  Color(0xFF3949AB),
  Color(0xFFE91E63),
  Color(0xFF43A047),
  Color(0xFF795548),
];

class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});
  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
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
            'Theme mode and accent color below apply just to your phone.',
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
          const SizedBox(height: 32),
          // Feature: home screen background — presets (same set your chats
          // already use, for a consistent look) + a custom photo option.
          // Per-chat wallpaper already has its own entry in each chat's own
          // Chat Settings screen ("Chat theme") — this is the home screen
          // list's background instead.
          Text('Home screen background', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Change background'),
              subtitle: const Text('Background behind your chat list'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HomeBackgroundScreen())),
            ),
          ),
        ],
      ),
    );
  }
}
