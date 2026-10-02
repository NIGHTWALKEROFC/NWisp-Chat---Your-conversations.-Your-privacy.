import 'package:flutter/material.dart';
import '../screens/security_chat_screen.dart';
import '../services/security_chat_lock_service.dart';
import '../services/security_chat_service.dart';

/// The "NWisp Chat Notifications" row in the chat list (see
/// SecurityChatService). Shows the newest notice and how many are unread;
/// tapping it opens the read-only SecurityChatScreen.
class SecurityChatTile extends StatefulWidget {
  final SecurityNotice latest;
  final int unread;
  const SecurityChatTile({super.key, required this.latest, required this.unread});

  @override
  State<SecurityChatTile> createState() => _SecurityChatTileState();
}

class _SecurityChatTileState extends State<SecurityChatTile> {
  SecurityNotice get latest => widget.latest;
  int get unread => widget.unread;

  @override
  void initState() {
    super.initState();
    // Reads whether the optional chat lock is on (see SecurityChatLockService).
    SecurityChatLockService.instance.load();
  }

  String _when(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) {
      final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
    }
    if (diff == 1) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasUnread = unread > 0;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primary.withValues(alpha: 0.16),
        child: Icon(Icons.verified_user_rounded, color: scheme.primary),
      ),
      title: Row(
        children: [
          const Flexible(
            child: Text('NWisp Chat Notifications', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          Icon(Icons.verified_rounded, size: 16, color: scheme.primary),
        ],
      ),
      // While the chat lock is on, the row doesn't say what the latest alert is.
      subtitle: ValueListenableBuilder<int>(
        valueListenable: SecurityChatLockService.instance.changed,
        builder: (context, _, __) {
          final locked = SecurityChatLockService.instance.enabledCached;
          return Row(
            children: [
              if (locked) ...[
                Icon(Icons.lock_rounded, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  locked ? 'Locked' : latest.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasUnread && !locked ? scheme.onSurface : scheme.onSurfaceVariant,
                    fontWeight: hasUnread && !locked ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          );
        },
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(_when(latest.time), style: TextStyle(fontSize: 12, color: hasUnread ? scheme.primary : scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          if (hasUnread)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(12)),
              child: Text('$unread', style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
            )
          else
            const SizedBox(height: 18),
        ],
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityChatScreen())),
    );
  }
}
