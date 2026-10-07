import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

/// Feature: long-press app-icon shortcuts ("New message", "Scan QR code",
/// "Add story", "New group"). The phone shows them when you hold the NWisp
/// icon on the home screen; tapping one opens NWisp straight on that screen.
///
/// The tap only sets [pending]; HomeShell (which exists only after sign-in and
/// unlock) opens the screen — so a shortcut can never skip the app lock.
class QuickActionsService {
  QuickActionsService._();
  static final instance = QuickActionsService._();

  /// The shortcut that was just tapped, until HomeShell has handled it.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  bool _started = false;

  Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      const quick = QuickActions();
      await quick.initialize((type) => pending.value = type);
      await quick.setShortcutItems(const [
        ShortcutItem(type: 'new_message', localizedTitle: 'New message'),
        ShortcutItem(type: 'scan_qr', localizedTitle: 'Scan QR code'),
        ShortcutItem(type: 'add_story', localizedTitle: 'Add story'),
        ShortcutItem(type: 'new_group', localizedTitle: 'New group'),
      ]);
    } catch (e) {
      debugPrint('QuickActionsService.init: $e');
    }
  }

  void clear() => pending.value = null;
}
