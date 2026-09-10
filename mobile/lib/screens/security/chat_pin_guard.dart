import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/chat_lock_service.dart';
import 'pin_screen.dart';

/// Call this before navigating into ANY chat (1:1 or group). Returns true
/// immediately if the chat isn't locked. If it IS locked, prompts for the
/// app-wide PIN (setting one up first if the person hasn't already) and
/// only returns true once that's confirmed — returns false if they cancel
/// or enter the wrong PIN and back out, so the caller knows not to open
/// the chat.
///
/// Used from: ChatListScreen's row taps (1:1 and group), main.dart's
/// _openChat (so a tapped notification can't bypass this the same way it
/// already can't bypass hiding), and ChatDetailScreen's/GroupChatScreen's
/// own initState as a last-line check (covers any other entry point —
/// e.g. a deep link — that might reach the chat without having gone
/// through one of the above first).
Future<bool> requireChatPinIfLocked(BuildContext context, String conversationId) async {
  if (!await ChatLockService.isLocked(conversationId)) return true;

  if (!await AppLockService.isEnabled()) {
    if (!context.mounted) return false;
    final setUp = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Set up a PIN first'),
        content: const Text(
          '"Lock this chat" uses your app PIN, which isn\'t set up yet. Set one up now to open this chat.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Set up PIN')),
        ],
      ),
    );
    if (setUp != true || !context.mounted) return false;
    final result = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)));
    return result == true;
  }

  if (!context.mounted) return false;
  final result = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.verify)));
  return result == true;
}
