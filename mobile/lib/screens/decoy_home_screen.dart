import 'package:flutter/material.dart';

/// Feature: duress/panic PIN. Shown instead of the real chat list when
/// the panic PIN (not the real one) is entered on the lock screen. Looks
/// like a normal, freshly-installed copy of the app with no
/// conversations yet — deliberately a dead end:
///   - No real data of any kind ever touches this screen. It doesn't
///     read LocalMessageStore, Firestore, or anything else — there's
///     nothing here to accidentally leak.
///   - The "New chat" and "Settings" affordances are present (so it
///     reads as a real, working app to someone glancing at it under
///     duress) but don't lead anywhere real.
///   - There is deliberately no visible way to get back to the REAL
///     app from here. The only way out is the same way in: background
///     the app (or force-close it) and reopen it, which re-locks and
///     shows the PIN screen again — enter the REAL PIN there to get to
///     actual chats. That's intentional: a screen that could visibly
///     "switch back" to the real app under someone else's eyes would
///     defeat the entire point of this feature.
class DecoyHomeScreen extends StatelessWidget {
  const DecoyHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const _DecoySettingsScreen()),
            ),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 56, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text('No conversations yet', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No contacts yet')),
        ),
        child: const Icon(Icons.add_comment_outlined),
      ),
    );
  }
}

class _DecoySettingsScreen extends StatelessWidget {
  const _DecoySettingsScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: const [
          ListTile(leading: Icon(Icons.palette_outlined), title: Text('Theme & color')),
          ListTile(leading: Icon(Icons.privacy_tip_outlined), title: Text('Privacy Policy')),
          ListTile(leading: Icon(Icons.gavel_outlined), title: Text('Terms & Conditions')),
          ListTile(leading: Icon(Icons.help_outline), title: Text('Help Centre')),
        ],
      ),
    );
  }
}
