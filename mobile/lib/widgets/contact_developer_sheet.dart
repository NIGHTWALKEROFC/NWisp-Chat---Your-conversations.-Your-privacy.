import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _devInstagram = 'nightwalker.ofc';
const _devTelegram = 'nightwalker_ofc0';
const _devEmail = 'rinshan602@gmail.com';

Future<void> showContactDeveloperSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ContactDeveloperSheet(),
  );
}

class _ContactDeveloperSheet extends StatelessWidget {
  const _ContactDeveloperSheet();

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      trailing: const Icon(Icons.copy, size: 18),
      onTap: () => _copy(context, label, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Trouble accessing your account?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  SizedBox(height: 4),
                  Text('Reach out to the developer directly and we\'ll help you recover it. Tap any option to copy it.'),
                ],
              ),
            ),
            _row(context, Icons.camera_alt_outlined, 'Instagram', '@$_devInstagram'),
            _row(context, Icons.send_outlined, 'Telegram', '@$_devTelegram'),
            _row(context, Icons.email_outlined, 'Email', _devEmail),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
