import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

/// Pinned messages per conversation, stored as an ORDERED list (not a set)
/// so the pinned banner can show "most recently pinned first" and let you
/// cycle through them — the way WhatsApp/Telegram do. Capped at 3 pins per
/// chat, the same cap WhatsApp uses.
///
/// UPDATED — Feature: shared pins. Pinning used to be visible only on the
/// device that pinned it (this table is still stored device-locally, same
/// as before) — but now every pin/unpin ALSO sends a small control message
/// to the other person (see MessageRelayService.sendPinUpdate), so both
/// sides end up with the same pinned messages, matching how pinning
/// actually works in WhatsApp/Telegram: it's for the conversation, not
/// just for you. [togglePin] is still what the person who pins something
/// calls; [setPinned] is the new one-directional setter the RECEIVING
/// side calls when the other person's pin/unpin control message arrives —
/// it never re-sends anything, so the two devices can't end up bouncing
/// pin updates back and forth at each other.
class PinService {
  static const maxPinsPerChat = 3;

  static String _key(String conversationId) => 'pinned_msgs_$conversationId';

  // Feature: shared pins — lets ChatDetailScreen react live to a pin/unpin
  // that just arrived from the other person, instead of only ever
  // refreshing after ITS OWN button presses.
  static final _controllers = <String, StreamController<List<String>>>{};

  static StreamController<List<String>> _controllerFor(String conversationId) {
    return _controllers.putIfAbsent(conversationId, () => StreamController<List<String>>.broadcast());
  }

  static Future<void> _notify(String conversationId) async {
    final ids = await pinnedFor(conversationId);
    final c = _controllers[conversationId];
    if (c != null && !c.isClosed) c.add(ids);
  }

  static Future<List<String>> pinnedFor(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key(conversationId)) ?? [];
  }

  /// Emits the current pinned-id list whenever it changes (from either
  /// this device's own pin/unpin, or one that arrived from the other
  /// person) — and once immediately with whatever's already saved.
  static Stream<List<String>> watchPinned(String conversationId) {
    pinnedFor(conversationId).then((ids) {
      final c = _controllers[conversationId];
      if (c != null && !c.isClosed) c.add(ids);
    });
    return _controllerFor(conversationId).stream;
  }

  /// Pins/unpins [messageId] — call this from the side that's actually
  /// choosing to pin something; the caller is responsible for also
  /// telling the other person (see ChatDetailScreen._pinSelected, which
  /// calls MessageRelayService.sendPinUpdate right after this). Returns
  /// null on success, or a user-facing error message if the pin limit was
  /// hit.
  static Future<String?> togglePin(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key(conversationId)) ?? []).toList();
    if (current.contains(messageId)) {
      current.remove(messageId);
    } else {
      if (current.length >= maxPinsPerChat) {
        return 'You can only pin up to $maxPinsPerChat messages in a chat — unpin one first.';
      }
      current.add(messageId);
    }
    await prefs.setStringList(_key(conversationId), current);
    await _notify(conversationId);
    return null;
  }

  /// Explicit set-to-a-known-state, used on the RECEIVING side when a pin
  /// control message arrives from the other person (see
  /// MessageRelayService's 'pin_update' case) — deliberately not a toggle,
  /// since the incoming message already says exactly what the state
  /// should become, and a toggle here could flip the wrong way if a
  /// message somehow arrived twice.
  static Future<void> setPinned(String conversationId, String messageId, bool pinned) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key(conversationId)) ?? []).toList();
    final alreadyHas = current.contains(messageId);
    if (pinned && !alreadyHas) {
      if (current.length >= maxPinsPerChat) current.removeAt(0); // oldest pin makes room, mirrors the sender's own limit
      current.add(messageId);
    } else if (!pinned && alreadyHas) {
      current.remove(messageId);
    } else {
      return; // already in the requested state — nothing changed, no need to notify
    }
    await prefs.setStringList(_key(conversationId), current);
    await _notify(conversationId);
  }

  static Future<void> unpin(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key(conversationId)) ?? []).toList();
    current.remove(messageId);
    await prefs.setStringList(_key(conversationId), current);
    await _notify(conversationId);
  }

  static Future<void> clear(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(conversationId));
    await _notify(conversationId);
  }

  /// Wipes pinned-message state for EVERY conversation on this device —
  /// used when a different account signs in on this device (see
  /// SessionService), since old pin references would otherwise point at
  /// another account's messages.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('pinned_msgs_')).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
