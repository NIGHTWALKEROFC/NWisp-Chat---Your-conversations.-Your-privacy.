import 'package:flutter/material.dart';

/// Referenced from Terms & Conditions §5 and from ReportUserScreen/
/// SuspendedAccountScreen — this is the plain-English version of exactly
/// what each entry in `reportableRules` (moderation_service.dart) means,
/// so a report or a suspension always points back to a rule the person
/// can actually go read, not just a one-line label.
class CommunityGuidelinesScreen extends StatelessWidget {
  const CommunityGuidelinesScreen({super.key});

  static const _lastUpdated = 'September 2026';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Community Guidelines')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Last updated: $_lastUpdated', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(
            'These are the specific rules NWisp is moderated against. Every "Report" button in the '
            'app asks the reporter to pick one of these — the same list, word for word — so a '
            "report or a suspension always points back to something you can read here, not just a "
            'vague label.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 20),
          _Rule(
            title: 'Harassment or bullying',
            body: "Repeatedly contacting someone who's asked you to stop, targeting someone with "
                'insults or intimidation, encouraging others to pile on a person, or using the app '
                "to follow, monitor, or intimidate someone. Disagreeing with someone isn't "
                'harassment — a sustained pattern aimed at a specific person is.',
          ),
          _Rule(
            title: 'Spam or scams',
            body: 'Mass-messaging people who never contacted you, forwarded chain messages at '
                'scale, fake giveaways, phishing links, impersonating a business or a payment '
                'service, or any attempt to trick someone out of money, credentials, or personal '
                'information.',
          ),
          _Rule(
            title: 'Impersonation',
            body: "Pretending to be another real person — using their name, photos, or claiming to "
                "be them — without their consent. This includes accounts that exist mainly to "
                'confuse people about who they\'re really talking to.',
          ),
          _Rule(
            title: 'Sharing illegal content',
            body: 'Content that is illegal to possess or distribute where you or the recipient are '
                'located — this covers a wide range depending on jurisdiction, and when in doubt, '
                "don't send it.",
          ),
          _Rule(
            title: 'Sexual content involving a minor',
            body: 'Zero tolerance, no exceptions, regardless of context, framing, or claimed intent. '
                'This is reported to the relevant authorities in addition to any action taken on the '
                'account.',
          ),
          _Rule(
            title: 'Violence or threats',
            body: 'Threatening someone with harm, encouraging violence against a person or group, '
                'or sharing graphic violent content intended to shock or intimidate rather than to '
                'inform.',
          ),
          _Rule(
            title: 'Hate speech',
            body: 'Attacking a person or group based on race, ethnicity, national origin, religion, '
                'disability, sexual orientation, gender identity, or similar protected '
                'characteristics — including slurs, dehumanizing language, or promoting hatred '
                'against that group.',
          ),
          _Rule(
            title: 'Other',
            body: 'Anything that seriously harms another person and isn\'t covered above — the '
                'report\'s optional details field is where to explain what happened so it can be '
                'reviewed properly.',
          ),
          const SizedBox(height: 12),
          _Rule(
            title: 'How this is enforced',
            body: 'Reports are reviewed by a real person, not automatically — there\'s no bot '
                'silently reading your messages to check these rules, since NWisp is end-to-end '
                'encrypted and the server can\'t read message content at all (see the Privacy '
                'Policy). Enforcement only ever happens off what a reporter actually submits: which '
                'rule, any details, and any proof they attach. An account found to have broken one '
                'of these rules may be suspended, with the specific rule shown to that account and a '
                'chance to appeal — see Terms & Conditions §10.',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  final String title;
  final String body;
  const _Rule({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        ],
      ),
    );
  }
}
