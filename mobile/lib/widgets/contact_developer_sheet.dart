import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const _devInstagram = 'nightwalker.ofc';
const _devTelegram = 'nightwalker_ofc0';
const _devEmail = 'rinshan602@gmail.com';

const _instagramUrl = 'https://instagram.com/$_devInstagram';
const _telegramUrl = 'https://t.me/$_devTelegram';
const _emailUrl = 'mailto:$_devEmail';

Future<void> showContactDeveloperSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ContactDeveloperSheet(),
  );
}

class _ContactDeveloperSheet extends StatelessWidget {
  const _ContactDeveloperSheet();

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open that link — the app may not be installed.")),
      );
    }
  }

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Widget _row(BuildContext context, IconData icon, String label, String value, String url) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      onTap: () => _open(context, url),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 18),
        tooltip: 'Copy',
        onPressed: () => _copy(context, label, value),
      ),
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
                  Text('Reach out to the developer directly. Tap a row to open it, or tap the copy icon.'),
                ],
              ),
            ),
            _row(context, Icons.camera_alt_outlined, 'Instagram', '@$_devInstagram', _instagramUrl),
            _row(context, Icons.send_outlined, 'Telegram', '@$_devTelegram', _telegramUrl),
            _row(context, Icons.email_outlined, 'Email', _devEmail, _emailUrl),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
