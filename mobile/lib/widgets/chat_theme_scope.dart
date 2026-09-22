import 'package:flutter/material.dart';
import '../services/chat_theme_service.dart';
import '../theme/app_theme.dart';

/// Wraps a whole chat screen so its accent colour follows the chat's own
/// theme. Sent bubbles, the send button, links and other accents inside
/// the chat all read the app's colour scheme — so giving the chat its own
/// scheme (built exactly the way the app builds its main one, from a single
/// colour) recolours all of them at once without touching any bubble code.
///
/// A chat with no chosen colour is left completely untouched.
class ChatThemeScope extends StatefulWidget {
  final String conversationId;
  final Widget child;
  const ChatThemeScope({super.key, required this.conversationId, required this.child});

  @override
  State<ChatThemeScope> createState() => _ChatThemeScopeState();
}

class _ChatThemeScopeState extends State<ChatThemeScope> {
  ChatAccent? _accent;

  @override
  void initState() {
    super.initState();
    ChatThemeService.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    ChatThemeService.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final accent = await ChatThemeService.getAccent(widget.conversationId);
    if (!mounted) return;
    if (accent?.id != _accent?.id) setState(() => _accent = accent);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    if (accent == null) return widget.child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: dark ? AppTheme.dark(accent.color) : AppTheme.light(accent.color),
      child: widget.child,
    );
  }
}
