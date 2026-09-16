import 'package:flutter/material.dart';
import '../../widgets/contact_developer_sheet.dart';
import 'community_guidelines_screen.dart';
import 'feature_guide_screen.dart';
import 'help_center_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_screen.dart';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// Everything read-only/reference — help, legal, the feature guide —
/// pulled out of the old flat settings_screen.dart list under one
/// "Help & About" home.
class HelpAboutScreen extends StatelessWidget {
  const HelpAboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & About')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Help Centre'),
            subtitle: const Text('FAQ and how to contact the developer'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HelpCenterScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.support_agent_outlined),
            title: const Text('Contact the developer'),
            onTap: () => showContactDeveloperSheet(context),
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('Feature guide'),
            subtitle: const Text('A quick reference for everything the app can do'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FeatureGuideScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.rule_outlined),
            title: const Text('Community Guidelines'),
            subtitle: const Text('The specific rules reports and suspensions are based on'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CommunityGuidelinesScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Terms & Conditions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TermsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
