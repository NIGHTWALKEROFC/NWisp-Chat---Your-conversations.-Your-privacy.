import 'package:flutter/material.dart';
import '../screens/security_chat_screen.dart';
import '../services/security_chat_service.dart';
import 'nwisp_ui.dart';

/// The pinned "NWisp Chat" row at the top of the chat list. Always there
/// (even with no notices yet), can't be deleted, archived or muted — it's
/// where the app tells you about your own account's security.
class SecurityChatTile extends StatelessWidget {
  final String uid;
  const SecurityChatTile({super.key, required this.uid});

  String _shortTime(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
    }
    final diff = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (diff == 1) return 'Yesterday';
    return '${t.month}/${t.day}/${t.year % 100}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // readTick makes the unread badge clear the moment the chat is opened.
    return ValueListenableBuilder<int>(
      valueListenable: SecurityChatService.instance.readTick,
      builder: (context, _, __) {
        return StreamBuilder<SecurityChatSummary>(
          stream: SecurityChatService.instance.summary(uid),
          builder: (context, snap) {
            final summary = snap.data;
            final latest = summary?.latest;
            final unread = summary?.unread ?? 0;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const NwispOfficialAvatar(radius: 26),
              title: Row(
                children: [
                  const Flexible(
                    child: Text(
                      'NWisp Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const VerifiedBadge(size: 15),
                ],
              ),
              subtitle: Text(
                latest?.title ?? 'Security alerts for your account',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: unread > 0 ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _shortTime(latest?.time),
                    style: TextStyle(fontSize: 12, color: unread > 0 ? scheme.primary : scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  if (unread > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        unread > 9 ? '9+' : '$unread',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onPrimary, fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                    )
                  else
                    const SizedBox(height: 18),
                ],
              ),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityChatScreen())),
            );
          },
        );
      },
    );
  }
}
