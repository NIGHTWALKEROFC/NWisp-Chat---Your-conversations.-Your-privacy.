import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../chat/chat_detail_screen.dart';
import '../security/chat_pin_guard.dart';

/// QR-code based contact adding — faster and more private than typing a
/// username into FindUsersScreen's search, and a natural fit for a
/// security-focused app (this is exactly how Signal's own "safety number
/// QR code" and most other secure messengers let two people connect in
/// person). The code encodes ONLY this account's uid (a random Firebase
/// Auth id, not the username, email, or phone number) behind a small
/// fixed prefix so a scan can be told apart from an arbitrary QR code
/// someone points the camera at by accident.
///
/// Feature: the Scan tab is now a WhatsApp-style scanner — a dimmed camera
/// with a square scanning box, corner marks, a moving scan line, flashlight,
/// camera flip and "scan from gallery".
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
  String _myName = '';

  @override
  void initState() {
    super.initState();
    _loadMyName();
    _tabController.addListener(() {
      // Only run the camera while the Scan tab is actually visible.
      if (_tabController.indexIsChanging) return;
      setState(() {
        if (_tabController.index == 1) {
          _scannerController ??= MobileScannerController(
            formats: const [BarcodeFormat.qrCode],
            detectionSpeed: DetectionSpeed.noDuplicates,
          );
        } else {
          _scannerController?.dispose();
          _scannerController = null;
        }
      });
    });
  }

  Future<void> _loadMyName() async {
    try {
      final doc = await AuthService().currentUserProfile();
      final name = (doc.data()?['username'] as String?) ?? '';
      if (mounted) setState(() => _myName = name);
    } catch (_) {}
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
          SnackBar(
            content: Text(
              scannedUid == FirebaseAuth.instance.currentUser?.uid
                  ? "That's your own code."
                  : "That code doesn't match a real account.",
            ),
          ),
        );
        return;
      }
      var username = ((user['username'] as String?) ?? '').trim();
      if (username.isEmpty) username = 'Unknown';
      await _showResultSheet(scannedUid, username);
    } finally {
      _handlingScan = false;
    }
  }

  Future<void> _scanFromGallery() async {
    final controller = _scannerController;
    if (controller == null) return;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final capture = await controller.analyzeImage(picked.path);
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No QR code found in that picture.')));
        return;
      }
      await _handleDetection(capture);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't read that picture.")));
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
                        // BUGFIX: see chat_pin_guard.dart's canOpenChat doc
                        // comment — a scanned QR code was another way to
                        // reach an already-hidden or paused chat directly.
                        if (!await canOpenChat(context, conversationId: conversationId, otherUid: uid)) return;
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
                          await _contactService.sendRequest(
                            toUid: uid,
                            toUsername: username == 'Unknown' ? '' : username,
                            myUsername: myUsername,
                          );
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

  Widget _scanTab() {
    final controller = _scannerController;
    if (controller == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = (constraints.biggest.shortestSide * 0.68).clamp(180.0, 320.0);
        final box = Rect.fromCenter(
          center: Offset(constraints.maxWidth / 2, constraints.maxHeight * 0.42),
          width: side,
          height: side,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: controller,
              scanWindow: box,
              onDetect: _handleDetection,
              errorBuilder: (context, error, child) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'The camera is not available. Allow camera access for NWisp in your phone settings, then try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ),
            ),
            // Dimmed area around the scanning box.
            IgnorePointer(child: CustomPaint(painter: _ScanOverlayPainter(box))),
            // Moving scan line.
            Positioned.fromRect(
              rect: box,
              child: const IgnorePointer(child: _ScanLine()),
            ),
            Positioned(
              left: 24,
              right: 24,
              top: box.bottom + 20,
              child: const Text(
                "Point your camera at someone's NWisp QR code",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundAction(
                    icon: Icons.flashlight_on_rounded,
                    label: 'Flash',
                    onTap: () => controller.toggleTorch(),
                  ),
                  const SizedBox(width: 28),
                  _RoundAction(
                    icon: Icons.photo_library_outlined,
                    label: 'Gallery',
                    onTap: _scanFromGallery,
                  ),
                  const SizedBox(width: 28),
                  _RoundAction(
                    icon: Icons.cameraswitch_outlined,
                    label: 'Flip',
                    onTap: () => controller.switchCamera(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
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
        physics: const NeverScrollableScrollPhysics(),
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
                  if (_myName.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(_myName, style: Theme.of(context).textTheme.titleLarge),
                  ],
                  const SizedBox(height: 14),
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
          Container(color: Colors.black, child: _scanTab()),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RoundAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.white24,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(14), child: Icon(icon, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}

/// Dark layer with a clear rounded square (the scanning box) and bright
/// corner marks.
class _ScanOverlayPainter extends CustomPainter {
  final Rect box;
  _ScanOverlayPainter(this.box);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(box, const Radius.circular(18));
    final dim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.62));

    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    const len = 30.0;
    const r = 18.0;
    final l = box.left, t = box.top, rt = box.right, b = box.bottom;
    final path = Path()
      // top-left
      ..moveTo(l, t + len)
      ..lineTo(l, t + r)
      ..arcToPoint(Offset(l + r, t), radius: const Radius.circular(r))
      ..lineTo(l + len, t)
      // top-right
      ..moveTo(rt - len, t)
      ..lineTo(rt - r, t)
      ..arcToPoint(Offset(rt, t + r), radius: const Radius.circular(r))
      ..lineTo(rt, t + len)
      // bottom-right
      ..moveTo(rt, b - len)
      ..lineTo(rt, b - r)
      ..arcToPoint(Offset(rt - r, b), radius: const Radius.circular(r))
      ..lineTo(rt - len, b)
      // bottom-left
      ..moveTo(l + len, b)
      ..lineTo(l + r, b)
      ..arcToPoint(Offset(l, b - r), radius: const Radius.circular(r))
      ..lineTo(l, b - len);
    canvas.drawPath(path, corner);
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter old) => old.box != box;
}

class _ScanLine extends StatefulWidget {
  const _ScanLine();

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          children: [
            Positioned(
              left: 14,
              right: 14,
              top: 14 + (constraints.maxHeight - 28) * _c.value,
              child: Container(
                height: 2.5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [BoxShadow(color: Colors.white.withValues(alpha: 0.5), blurRadius: 8)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
