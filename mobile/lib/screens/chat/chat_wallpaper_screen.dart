import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/chat_theme_service.dart';
import '../../services/chat_wallpaper_service.dart';

/// Feature: chat themes, per conversation. Shared by 1:1 and group chats.
///
/// Three things, all applied the moment you tap (no save step):
///  * Themes  — ready-made wallpaper + bubble colour combinations.
///  * Bubble colour — recolours sent bubbles, the send button and accents.
///  * Wallpapers — the background behind the messages.
///
/// Stored on this phone only; the other people in the chat never see it.
class ChatWallpaperScreen extends StatefulWidget {
  final String conversationId;
  const ChatWallpaperScreen({super.key, required this.conversationId});

  @override
  State<ChatWallpaperScreen> createState() => _ChatWallpaperScreenState();
}

class _ChatWallpaperScreenState extends State<ChatWallpaperScreen> {
  String _wallpaperId = 'default';
  String? _accentId;
  // Feature: custom photo backgrounds — only meaningful when _wallpaperId
  // == 'custom'; every preset ignores this.
  String? _customImagePath;
  bool _pickingPhoto = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = await ChatWallpaperService.getWallpaper(widget.conversationId);
    final a = await ChatThemeService.getAccent(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _wallpaperId = w.id;
      _customImagePath = w.imagePath;
      _accentId = a?.id;
    });
  }

  ChatWallpaper get _wallpaper => _wallpaperId == 'custom' && _customImagePath != null
      ? ChatWallpaper(id: 'custom', name: 'Custom photo', colors: const [], imagePath: _customImagePath)
      : kChatWallpapers.firstWhere((w) => w.id == _wallpaperId, orElse: () => kChatWallpapers.first);
  ChatAccent? get _accent {
    for (final a in kChatAccents) {
      if (a.id == _accentId) return a;
    }
    return null;
  }

  Future<void> _pickWallpaper(ChatWallpaper w) async {
    await ChatWallpaperService.setWallpaper(widget.conversationId, w.id);
    if (mounted) setState(() => _wallpaperId = w.id);
  }

  /// Feature: custom photo backgrounds — opens the gallery, saves the
  /// chosen photo into this app's own storage (see
  /// ChatWallpaperService.persistCustomImage — NOT the picker's temp
  /// path, which the OS can clear later), and sets it as this chat's
  /// wallpaper.
  Future<void> _pickCustomPhoto() async {
    setState(() => _pickingPhoto = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (picked == null) return;
      final path = await ChatWallpaperService.persistCustomImage(File(picked.path), widget.conversationId);
      await ChatWallpaperService.setCustomWallpaper(widget.conversationId, path);
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

  Future<void> _pickAccent(ChatAccent? a) async {
    await ChatThemeService.setAccent(widget.conversationId, a?.id);
    if (mounted) setState(() => _accentId = a?.id);
  }

  Future<void> _pickBundle(ChatThemeBundle b) async {
    await ChatThemeService.applyBundle(widget.conversationId, b);
    if (mounted) {
      setState(() {
        _wallpaperId = b.wallpaperId;
        _accentId = b.accentId;
      });
    }
  }

  Future<void> _reset() async {
    await ChatThemeService.reset(widget.conversationId);
    if (mounted) {
      setState(() {
        _wallpaperId = 'default';
        _customImagePath = null;
        _accentId = null;
      });
    }
  }

  ChatWallpaper _wallpaperById(String id) => kChatWallpapers.firstWhere((w) => w.id == id, orElse: () => kChatWallpapers.first);
  ChatAccent _accentById(String id) => kChatAccents.firstWhere((a) => a.id == id, orElse: () => kChatAccents.first);

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
        child: Text(text, style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final previewScheme = _accent == null ? scheme : ColorScheme.fromSeed(seedColor: _accent!.color, brightness: brightness);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat theme'),
        actions: [TextButton(onPressed: _reset, child: const Text('Reset'))],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ---- live preview ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _ChatPreview(wallpaper: _wallpaper, scheme: previewScheme, baseScheme: scheme),
          ),

          // ---- themes ----
          _sectionTitle('Themes'),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: kChatThemeBundles.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final b = kChatThemeBundles[i];
                final w = _wallpaperById(b.wallpaperId);
                final a = _accentById(b.accentId);
                final selected = _wallpaperId == b.wallpaperId && _accentId == b.accentId;
                final sc = ColorScheme.fromSeed(seedColor: a.color, brightness: brightness);
                return GestureDetector(
                  onTap: () => _pickBundle(b),
                  child: SizedBox(
                    width: 96,
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: w.colors.length > 1 ? LinearGradient(colors: w.colors, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
                              color: w.colors.length == 1 ? w.colors.first : scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 3 : 1),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Align(alignment: Alignment.centerLeft, child: _miniBubble(scheme.surfaceContainerHigh, 34)),
                                const SizedBox(height: 6),
                                Align(alignment: Alignment.centerRight, child: _miniBubble(sc.primary, 44)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(b.name, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // ---- bubble colour ----
          _sectionTitle('Bubble colour'),
          SizedBox(
            height: 64,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _accentDot(scheme, label: 'Default', color: scheme.primary, selected: _accentId == null, onTap: () => _pickAccent(null)),
                for (final a in kChatAccents)
                  _accentDot(scheme, label: a.name, color: a.color, selected: _accentId == a.id, onTap: () => _pickAccent(a)),
              ],
            ),
          ),

          // ---- wallpapers ----
          _sectionTitle('Wallpapers'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.72),
              // Feature: custom photo backgrounds — one extra tile at the
              // end of the preset grid.
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
                  onTap: () => _pickWallpaper(w),
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
        ],
      ),
    );
  }

  Widget _miniBubble(Color color, double width) => Container(
        width: width,
        height: 14,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      );

  Widget _accentDot(ColorScheme scheme, {required String label, required Color color, required bool selected, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? scheme.onSurface : Colors.transparent, width: 3),
              ),
              child: selected ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
            ),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

/// A small sample conversation showing the chosen wallpaper and colour.
class _ChatPreview extends StatelessWidget {
  final ChatWallpaper wallpaper;
  final ColorScheme scheme; // the chosen accent's scheme (or the app's)
  final ColorScheme baseScheme;
  const _ChatPreview({required this.wallpaper, required this.scheme, required this.baseScheme});

  @override
  Widget build(BuildContext context) {
    Widget bubble(String text, {required bool mine}) => Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? scheme.primary : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(text, style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface)),
          ),
        );

    return Container(
      height: 150,
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: wallpaper.imagePath == null && wallpaper.colors.isEmpty
            ? baseScheme.surface
            : (wallpaper.imagePath == null && wallpaper.colors.length == 1 ? wallpaper.colors.first : null),
        gradient: wallpaper.imagePath == null && wallpaper.colors.length > 1
            ? LinearGradient(colors: wallpaper.colors, begin: Alignment.topLeft, end: Alignment.bottomRight)
            : null,
        image: wallpaper.imagePath != null ? DecorationImage(image: FileImage(File(wallpaper.imagePath!)), fit: BoxFit.cover) : null,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: baseScheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          bubble('Hey! How does this look?', mine: false),
          bubble('Looks great 👌', mine: true),
        ],
      ),
    );
  }
}
