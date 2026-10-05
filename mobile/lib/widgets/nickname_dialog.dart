import 'package:flutter/material.dart';
import '../services/nickname_service.dart';

/// Asks for a private nickname for [uid]. Only this phone ever sees it.
Future<void> showNicknameDialog(BuildContext context, {required String uid, required String realName}) async {
  final controller = TextEditingController(text: NicknameService.instance.nicknameFor(uid) ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Nickname for $realName'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLength: 30,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'e.g. Mom, Work Rinshan'),
          ),
          const SizedBox(height: 4),
          Text(
            'Only you can see this. $realName is never told, and their real username stays on their profile.',
            style: TextStyle(fontSize: 12.5, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        if (NicknameService.instance.nicknameFor(uid) != null)
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
  controller.dispose();
  if (result == null) return;
  await NicknameService.instance.setNickname(uid, result);
}
