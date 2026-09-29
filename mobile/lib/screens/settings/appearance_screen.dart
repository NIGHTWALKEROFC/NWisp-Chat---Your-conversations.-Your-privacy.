import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/branding_service.dart';
import '../../services/theme_service.dart';
import '../../theme/app_theme.dart';
import 'home_background_screen.dart';

const _accentPresets = [
  // The five from the design sheet first…
  Color(0xFF4C7DFF),
  Color(0xFF7B5CFF),
  Color(0xFF1FBF8F),
  Color(0xFFFF8A3D),
  Color(0xFFFF4D6D),
  // …then the older curated set, so nobody loses a colour they had.
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
  Color(0xFF00BFA5),
  Color(0xFFFFB300),
  Color(0xFF3949AB),
  Color(0xFF43A047),
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
    final currentAccent = branding.accentColor ?? AppTheme.defaultSeedColor;

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Theme mode, accent color and text size below apply just to your phone.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _ThemeModeCard(
                  label: 'Dark',
                  icon: Icons.dark_mode_outlined,
                  preview: const [Color(0xFF070B1A), Color(0xFF1A2347)],
                  selected: themeService.mode == ThemeMode.dark,
                  onTap: () => themeService.setMode(ThemeMode.dark),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ThemeModeCard(
                  label: 'Light',
                  icon: Icons.light_mode_outlined,
                  preview: const [Color(0xFFF6F8FE), Color(0xFFD5DDF2)],
                  selected: themeService.mode == ThemeMode.light,
                  onTap: () => themeService.setMode(ThemeMode.light),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ThemeModeCard(
                  label: 'System',
                  icon: Icons.brightness_auto_outlined,
                  preview: const [Color(0xFF070B1A), Color(0xFFF6F8FE)],
                  selected: themeService.mode == ThemeMode.system,
                  onTap: () => themeService.setMode(ThemeMode.system),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('Accent Color', style: Theme.of(context).textTheme.titleMedium),
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
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: currentAccent == color ? Border.all(color: scheme.onSurface, width: 2.5) : null,
                    ),
                    child: DecoratedBox(decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  ),
                ),
              GestureDetector(
                onTap: () => _openCustomColorPicker(branding),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
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
          Text('Font Size', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: ThemeService.normalScale, label: Text('Normal')),
              ButtonSegment(value: ThemeService.largeScale, label: Text('Large')),
            ],
            selected: {themeService.fontScale >= ThemeService.largeScale ? ThemeService.largeScale : ThemeService.normalScale},
            showSelectedIcon: false,
            onSelectionChanged: (s) => themeService.setFontScale(s.first),
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

/// One of the three Dark / Light / System tiles. The little two-tone block
/// is a mini preview of that theme's colours.
class _ThemeModeCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<Color> preview;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeModeCard({
    required this.label,
    required this.icon,
    required this.preview,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.7),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: preview,
                ),
              ),
              child: Icon(icon, color: preview.first.computeLuminance() > 0.5 ? Colors.black54 : Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
