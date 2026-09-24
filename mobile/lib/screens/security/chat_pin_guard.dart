import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/chat_freeze_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/device_session_service.dart';
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
  // Feature: multiple devices (off by default) — checked first, here,
  // rather than duplicated at every call site: canOpenChat already routes
  // through this function for its own callers, and the few places that
  // call this directly (ChatListScreen, the Community screens) get the
  // same coverage for free. On the overwhelming majority of accounts
  // (multi-device never turned on) this check is a single fast read that
  // always says yes and changes nothing.
  if (!await requirePrimaryDeviceForChat(context)) return false;
  if (!context.mounted) return false;
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

/// Feature: multiple devices (off by default). Call this alongside
/// [requireChatPinIfLocked] before navigating into ANY chat. On an account
/// that never turned Multiple devices on, or on the one device that holds
/// the account's actual Signal identity, this returns true immediately —
/// nothing changes for the overwhelming majority of people. On a SECOND
/// signed-in device that isn't the primary one, it explains — honestly,
/// not as a vague "coming soon" — why this specific device can't open
/// chats: it was never given the private key new messages are encrypted
/// against, and has no local message history either, so there's nothing
/// here it's able to decrypt or show. Offers a direct path to Account
/// security to either make this device primary or manage devices.
Future<bool> requirePrimaryDeviceForChat(BuildContext context) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return true;
  if (await DeviceSessionService.instance.isPrimaryDevice(uid)) return true;
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("Messaging isn't available on this device"),
      content: const Text(
        'Your messages are end-to-end encrypted to one device at a time — this one isn\'t currently it, so it has no way to '
        'decrypt chats. You can still use this device for contacts, groups, Communities, and settings.\n\n'
        'Go to Settings > Account security > Multiple devices to make this your primary device instead, or to manage your '
        'other devices.',
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK')),
      ],
    ),
  );
  return false;
}

/// BUGFIX (2026-09-11): hidden chats and paused chats were only ever kept
/// out of the normal chat list — [requireChatPinIfLocked] above (and the
/// hidden check in main.dart's notification handler) covered the intended
/// front doors, but three OTHER doors into the exact same conversationId
/// were left wide open: tapping a contact from ContactsScreen, tapping a
/// scanned QR code, and tapping a search result in FindUsersScreen all
/// pushed straight into ChatDetailScreen/GroupChatScreen with no check at
/// all. Any of those reaches the SAME conversation a hidden or paused chat
/// already lives at (the id is deterministic from the two uids), so all
/// three were a real way around both features. This is the combined check
/// those three call sites now use instead of pushing directly.
///
/// [otherUid] is only meaningful for 1:1 (pass null for a group — pausing
/// is a 1:1-only feature, see ChatFreezeService's own doc comment).
/// Returns true only if it's fine to navigate in.
Future<bool> canOpenChat(BuildContext context, {required String conversationId, String? otherUid}) async {
  if (await ChatLockService.isHidden(conversationId)) return false; // silent, same as the notification-tap case — no hint it exists

  if (otherUid != null) {
    final frozenUntil = await ChatFreezeService.instance.activeFreezeExpiry(otherUid);
    if (frozenUntil != null) {
      if (!context.mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('This chat is paused'),
          content: const Text('Resume it from Paused Chats in Settings to open it again.'),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK'))],
        ),
      );
      return false;
    }
  }

  return requireChatPinIfLocked(context, conversationId);
}
