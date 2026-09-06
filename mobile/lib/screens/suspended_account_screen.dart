import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import 'settings/community_guidelines_screen.dart';
import 'submit_appeal_screen.dart';

/// Shown by AuthGate instead of the normal app when this account's
/// accountStatus is 'suspended' (see the reporting/admin-review feature —
/// MODERATION_GUIDE.md explains exactly how you set this by hand in the
/// Firebase console). Distinct from ReactivateAccountScreen, which is for
/// the person's OWN "temporarily deactivate" choice, not an admin action.
class SuspendedAccountScreen extends StatefulWidget {
  const SuspendedAccountScreen({super.key});

  @override
  State<SuspendedAccountScreen> createState() => _SuspendedAccountScreenState();
}

class _SuspendedAccountScreenState extends State<SuspendedAccountScreen> {
  late final Future<_SuspensionInfo> _infoFuture = _loadInfo();

  Future<_SuspensionInfo> _loadInfo() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const _SuspensionInfo(reason: null, appealDisabled: false, contactUrl: null);

    final db = FirebaseFirestore.instance;
    final profileSnap = await db.collection('users').doc(uid).collection('private').doc('profile').get();
    final configSnap = await db.collection('config').doc('moderation').get();

    return _SuspensionInfo(
      reason: profileSnap.data()?['suspensionReason'] as String?,
      appealDisabled: (profileSnap.data()?['suspensionAppealDisabled'] as bool?) ?? false,
      contactUrl: configSnap.data()?['contactSocialUrl'] as String?,
    );
  }

  Future<void> _openAppeal() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SubmitAppealScreen()));
  }

  Future<void> _openContactLink(String url) async {
    // BUGFIX: admins commonly type a link without "https://" in front
    // (e.g. "instagram.com/username") — Uri.tryParse accepts that as a
    // schemeless relative URI, and launchUrl would then just silently do
    // nothing with no error shown anywhere. Add the scheme if it's
    // missing instead of failing quietly.
    final normalized = url.contains('://') ? url : 'https://$url';
    final uri = Uri.tryParse(normalized);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("This contact link isn't valid. Try Sign out and reach out another way.")),
      );
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open that link.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open that link: $e')),
      );
    }
  }

  Future<void> _signOut() => AuthService().logout();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: FutureBuilder<_SuspensionInfo>(
              future: _infoFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }
                final info = snapshot.data!;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gpp_bad_outlined, size: 56, color: scheme.error),
                    const SizedBox(height: 16),
                    Text(
                      'Your account was suspended',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      info.reason != null
                          ? 'Reason: ${info.reason}'
                          : 'No specific reason was recorded for this suspension.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CommunityGuidelinesScreen()),
                      ),
                      child: const Text('See what this rule means'),
                    ),
                    const SizedBox(height: 28),
                    if (info.appealDisabled) ...[
                      const Text(
                        "A previous appeal on this account wasn't accepted, so this account can no "
                        "longer submit a new one here.",
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      // BUGFIX: if the admin hasn't set config/moderation's
                      // contactSocialUrl yet (it's optional — see
                      // MODERATION_GUIDE.md), this used to show NEITHER
                      // button at all: no Appeal (correctly hidden) and no
                      // Contact admin (silently skipped since contactUrl
                      // was null) — a real dead end with only "Sign out"
                      // left. Always show something actionable instead.
                      if (info.contactUrl != null)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () => _openContactLink(info.contactUrl!),
                            child: const Text('Contact admin'),
                          ),
                        )
                      else
                        Text(
                          "No contact method has been set up yet for this. Please sign out and reach "
                          "out another way.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                    ] else
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(onPressed: _openAppeal, child: const Text('Appeal')),
                      ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _signOut, child: const Text('Sign out')),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SuspensionInfo {
  final String? reason;
  final bool appealDisabled;
  final String? contactUrl;
  const _SuspensionInfo({required this.reason, required this.appealDisabled, required this.contactUrl});
}
