import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../widgets/contact_developer_sheet.dart';
import 'community_guidelines_screen.dart';
import 'feature_guide_screen.dart';
import 'help_center_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_screen.dart';

// Feature: "On our website" section below. These mirror the pages actually
// published on the NWisp Chat website (nightwalkerofc.github.io/NWisp-Chat-WEBSITE),
// so a tap here opens the exact same page a browser would show at that URL —
// nothing is duplicated or re-typed in-app for these ones.
const _websiteBase = 'https://nightwalkerofc.github.io/NWisp-Chat-WEBSITE';
const _urlHome = '$_websiteBase/index.html';
const _urlFaq = '$_websiteBase/index.html#faq';
const _urlHelpCenter = '$_websiteBase/help-center.html';
const _urlAccountRecovery = '$_websiteBase/account-recovery.html';
const _urlSecurity = '$_websiteBase/security.html';
const _urlCompare = '$_websiteBase/compare.html';
const _urlCommunityGuidelines = '$_websiteBase/community-guidelines.html';
const _urlPrivacyPolicy = '$_websiteBase/privacy-policy.html';
const _urlTerms = '$_websiteBase/terms.html';
const _urlUpdates = '$_websiteBase/updates.html';
const _urlGithub = 'https://github.com/NIGHTWALKEROFC';

/// Feature: settings reorganized into WhatsApp-style category pages.
/// Everything read-only/reference — help, legal, the feature guide —
/// pulled out of the old flat settings_screen.dart list under one
/// "Help & About" home.
class HelpAboutScreen extends StatelessWidget {
  const HelpAboutScreen({super.key});

  /// Opens a website URL in the person's browser (same launchUrl pattern
  /// as widgets/contact_developer_sheet.dart), with the same "couldn't
  /// open that link" fallback if nothing can handle it.
  Future<void> _openWebsite(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open that link. Check your internet connection and try again.")),
      );
    }
  }

  Widget _webLink(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required String url,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _openWebsite(context, url),
    );
  }

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

          // ---- On our website (NEW) -----------------------------------
          // Feature: every page/section from the NWisp Chat website, each
          // opening directly in the browser. Kept in its own section,
          // separate from the in-app pages above, since these leave the
          // app instead of showing content inline.
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'ON OUR WEBSITE',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, letterSpacing: 0.6),
            ),
          ),
          _webLink(
            context,
            icon: Icons.language,
            title: 'NWisp Chat website',
            subtitle: 'nightwalkerofc.github.io/NWisp-Chat-WEBSITE',
            url: _urlHome,
          ),
          _webLink(
            context,
            icon: Icons.quiz_outlined,
            title: 'FAQ',
            subtitle: 'Frequently asked questions',
            url: _urlFaq,
          ),
          _webLink(
            context,
            icon: Icons.support_outlined,
            title: 'Help Centre (website)',
            subtitle: 'The full web version, with more detail than the in-app one',
            url: _urlHelpCenter,
          ),
          _webLink(
            context,
            icon: Icons.lock_reset_outlined,
            title: 'Account Recovery',
            subtitle: "Steps to get back in if you're locked out",
            url: _urlAccountRecovery,
          ),
          _webLink(
            context,
            icon: Icons.shield_outlined,
            title: 'Security',
            subtitle: 'How NWisp Chat protects your messages',
            url: _urlSecurity,
          ),
          _webLink(
            context,
            icon: Icons.compare_arrows,
            title: 'NWisp Chat vs other apps',
            subtitle: 'How it compares to Signal, WhatsApp & Telegram',
            url: _urlCompare,
          ),
          _webLink(
            context,
            icon: Icons.rule_outlined,
            title: 'Community Guidelines (website)',
            url: _urlCommunityGuidelines,
          ),
          _webLink(
            context,
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy (website)',
            url: _urlPrivacyPolicy,
          ),
          _webLink(
            context,
            icon: Icons.gavel_outlined,
            title: 'Terms & Conditions (website)',
            url: _urlTerms,
          ),
          _webLink(
            context,
            icon: Icons.new_releases_outlined,
            title: 'Updates',
            subtitle: "What's changed in each version",
            url: _urlUpdates,
          ),
          _webLink(
            context,
            icon: Icons.code,
            title: 'GitHub',
            subtitle: '@NIGHTWALKEROFC',
            url: _urlGithub,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
