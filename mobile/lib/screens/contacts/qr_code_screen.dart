import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../chat/chat_detail_screen.dart';

/// QR-code based contact adding — faster and more private than typing a
/// username into FindUsersScreen's search, and a natural fit for a
/// security-focused app (this is exactly how Signal's own "safety number
/// QR code" and most other secure messengers let two people connect in
/// person). The code encodes ONLY this account's uid (a random Firebase
/// Auth id, not the username, email, or phone number) behind a small
/// fixed prefix so a scan can be told apart from an arbitrary QR code
/// someone points the camera at by accident.
class QrCodeScreen extends StatefulWidget {
  const QrCodeScreen({super.key});

  @override
  State<QrCodeScreen> createState() => _QrCodeScreenState();
}

class _QrCodeScreenState extends State<QrCodeScreen> with SingleTickerProviderStateMixin {
  static const _prefix = 'nwisp:contact:';
  final _contactService = ContactService();
  final _conversationService = ConversationService();
  late final TabController _tabController = TabController(length: 2, vsync: this);
  MobileScannerController? _scannerController;
  bool _handlingScan = false;

  @override
  void initState() {
    super.initState();
    _tabController.addListener(() {
      // Only run the camera while the Scan tab is actually visible —
      // no reason to keep it warm (and the flashlight/lens active) while
      // looking at your own code.
      if (_tabController.indexIsChanging) return;
      // BUGFIX: this used to create/dispose _scannerController without
      // calling setState — the controller was created, but the widget
      // tree never rebuilt to swap the placeholder SizedBox.shrink() out
      // for the actual MobileScanner, so the Scan tab stayed permanently
      // blank with no camera preview.
      setState(() {
        if (_tabController.index == 1) {
          _scannerController ??= MobileScannerController();
        } else {
          _scannerController?.dispose();
          _scannerController = null;
        }
      });
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_handlingScan) return;
    if (capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null || !raw.startsWith(_prefix)) return;
    final scannedUid = raw.substring(_prefix.length);
    if (scannedUid.isEmpty) return;

    _handlingScan = true;
    try {
      final user = await _contactService.userByUid(scannedUid);
      if (!mounted) return;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("That code doesn't match a real account.")),
        );
        return;
      }
      final username = (user['username'] as String?) ?? 'Unknown';
      await _showResultSheet(scannedUid, username);
    } finally {
      _handlingScan = false;
    }
  }

  Future<void> _showResultSheet(String uid, String username) async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(radius: 28, child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?')),
              const SizedBox(height: 12),
              Text(username, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        final myUid = FirebaseAuth.instance.currentUser!.uid;
                        final conversationId = _conversationService.conversationIdFor(myUid, uid);
                        await _conversationService.ensureConversation(otherUid: uid);
                        if (!mounted) return;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatDetailScreen(conversationId: conversationId, peerUid: uid, peerUsername: username),
                          ),
                        );
                      },
                      child: const Text('Message'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        try {
                          final myProfile = await AuthService().currentUserProfile();
                          final myUsername = (myProfile.data()?['username'] as String?) ?? '';
                          await _contactService.sendRequest(toUid: uid, toUsername: username, myUsername: myUsername);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Contact request sent to $username')));
                        } catch (e) {
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
                          );
                        }
                      },
                      child: const Text('Add contact'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR code'),
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: 'My code'), Tab(text: 'Scan')]),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                    child: myUid == null
                        ? const SizedBox(height: 220, width: 220)
                        : QrImageView(
                            data: '$_prefix$myUid',
                            version: QrVersions.auto,
                            size: 220,
                          ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Let someone scan this to add you as a contact — it only encodes your account id, '
                    'not your username, email, or phone number.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          _scannerController == null
              ? const SizedBox.shrink()
              : MobileScanner(controller: _scannerController, onDetect: _handleDetection),
        ],
      ),
    );
  }
}
