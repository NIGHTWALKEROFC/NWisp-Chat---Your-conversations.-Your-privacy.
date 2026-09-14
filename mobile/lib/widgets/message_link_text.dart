import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/link_safety_service.dart';

/// Feature: in-app scam/phishing link warning. Shared by both
/// chat_detail_screen.dart and group_chat_screen.dart so a link inside a
/// message is handled identically everywhere in the app — always shows
/// where it actually leads before opening it, and always shows an extra
/// heuristic warning line when LinkSafetyService flags it (see that
/// file for exactly what it checks and why).
///
/// This dialog shows for EVERY link, not just flagged ones — that's
/// deliberate. A phishing link's whole trick is looking like something
/// else; the one thing that reliably defeats that is showing the real
/// domain before committing to open it, every single time, not just
/// when a heuristic happens to fire.
Future<void> openMessageLink(BuildContext context, String url) async {
  final host = LinkSafetyService.hostOf(url);
  final reason = LinkSafetyService.flagReason(url);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Open this link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(host.isEmpty ? url : host, style: const TextStyle(fontWeight: FontWeight.w700)),
          if (reason != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: Theme.of(dialogContext).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(child: Text(reason, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error, fontSize: 13))),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        FilledButton(
          style: reason != null ? FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error) : null,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(reason != null ? 'Open anyway' : 'Open'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open that link")));
  }
}

/// Splits [text] into normal spans plus tappable link spans wherever a
/// URL appears, using [baseStyle] for normal text and a link-styled
/// (underlined, colored) variant for the URL itself. Meant to be spliced
/// into an existing list of TextSpans — see how both chat screens call
/// this on each of their own already-built plain-text spans (e.g. after
/// splitting out @mentions) rather than replacing their text rendering
/// wholesale.
List<InlineSpan> linkifySpan(BuildContext context, String text, TextStyle baseStyle, {required Color linkColor}) {
  final matches = LinkSafetyService.urlPattern.allMatches(text).toList();
  if (matches.isEmpty) return [TextSpan(text: text, style: baseStyle)];
  final spans = <InlineSpan>[];
  var lastEnd = 0;
  for (final match in matches) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start), style: baseStyle));
    }
    final url = match.group(0)!;
    spans.add(TextSpan(
      text: url,
      style: baseStyle.copyWith(color: linkColor, decoration: TextDecoration.underline),
      recognizer: TapGestureRecognizer()..onTap = () => openMessageLink(context, url),
    ));
    lastEnd = match.end;
  }
  if (lastEnd < text.length) spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
  return spans;
}
