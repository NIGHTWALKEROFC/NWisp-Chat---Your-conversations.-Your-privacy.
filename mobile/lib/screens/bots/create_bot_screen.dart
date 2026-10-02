import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/bot_service.dart';
import 'bot_token_screen.dart';

enum _Check { idle, checking, available, taken, invalid }

/// Create a NWisp bot — no BotFather needed. Pick a username (it always ends
/// in _bot, which is shown for you), a name, optional description and
/// picture, and which features the bot may use (all start OFF).
class CreateBotScreen extends StatefulWidget {
  const CreateBotScreen({super.key});

  @override
  State<CreateBotScreen> createState() => _CreateBotScreenState();
}

class _CreateBotScreenState extends State<CreateBotScreen> {
  final _base = TextEditingController();
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final Map<String, bool> _rules = {for (final r in BotService.rules) r.key: false};
  _Check _check = _Check.idle;
  String? _problem;
  int _requestId = 0;
  Timer? _debounce;
  String? _photoData;
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _base.dispose();
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  String get _full => '${_base.text.trim().toLowerCase()}_bot';

  void _onBase(String value) {
    _debounce?.cancel();
    final v = value.trim().toLowerCase();
    if (v.isEmpty) {
      setState(() => _check = _Check.idle);
      return;
    }
    final local = BotService.validateBase(v);
    if (local != null) {
      setState(() {
        _check = _Check.invalid;
        _problem = local;
      });
      return;
    }
    setState(() => _check = _Check.checking);
    final id = ++_requestId;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final r = await BotService.instance.checkUsername('${v}_bot');
      if (!mounted || id != _requestId) return;
      setState(() {
        if (r == null) {
          _check = _Check.invalid;
          _problem = "Couldn't check right now — check your connection.";
        } else if (!r.valid) {
          _check = _Check.invalid;
          _problem = r.reason ?? 'Not allowed.';
        } else {
          _check = r.available ? _Check.available : _Check.taken;
        }
      });
    });
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 256, maxHeight: 256, imageQuality: 70);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _photoData = 'data:image/jpeg;base64,${base64Encode(bytes)}');
  }

  Widget? _status(ColorScheme scheme) {
    switch (_check) {
      case _Check.idle:
        return null;
      case _Check.checking:
        return const Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Checking availability…'),
        ]);
      case _Check.available:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
          const SizedBox(width: 6),
          Text('@$_full is available', style: TextStyle(color: Colors.green.shade600)),
        ]);
      case _Check.taken:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cancel, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Text('Already taken', style: TextStyle(color: scheme.error)),
        ]);
      case _Check.invalid:
        return Text(_problem ?? 'Not allowed', style: TextStyle(color: scheme.error, fontSize: 12.5));
    }
  }

  bool get _canCreate => _check == _Check.available && _name.text.trim().isNotEmpty && !_creating;

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final r = await BotService.instance.createBot(
        username: _full,
        name: _name.text.trim(),
        description: _desc.text.trim(),
        photoData: _photoData,
        rules: _rules,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => BotTokenScreen(username: r.bot.username, token: r.token)),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New bot')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: GestureDetector(
              onTap: _pickPhoto,
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 46,
                    backgroundColor: scheme.primary.withValues(alpha: 0.15),
                    backgroundImage: _photoData == null ? null : MemoryImage(base64Decode(_photoData!.substring(_photoData!.indexOf(',') + 1))),
                    child: _photoData == null ? Icon(Icons.smart_toy_rounded, size: 44, color: scheme.primary) : null,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(radius: 15, backgroundColor: scheme.primary, child: Icon(Icons.camera_alt, size: 16, color: scheme.onPrimary)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Center(child: Text('Picture (optional)', style: TextStyle(fontSize: 12.5))),
          const SizedBox(height: 18),
          const Text('Bot username', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          TextField(
            controller: _base,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: _onBase,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
              TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toLowerCase())),
              LengthLimitingTextInputFormatter(28),
            ],
            decoration: const InputDecoration(
              prefixText: '@',
              hintText: 'nwisp',
              suffixText: '_bot',
              suffixStyle: TextStyle(fontWeight: FontWeight.w800),
              border: OutlineInputBorder(),
              helperText: 'Every bot username ends with _bot',
            ),
          ),
          const SizedBox(height: 6),
          if (_status(scheme) != null) _status(scheme)!,
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            maxLength: 64,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Bot name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _desc,
            maxLength: 300,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Description (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 14),
          Row(children: [
            const Icon(Icons.tune_rounded, size: 20),
            const SizedBox(width: 8),
            const Text('Bot rules', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ]),
          const SizedBox(height: 4),
          const Text('Everything starts OFF. Turn on only what your bot needs — you can change this any time.', style: TextStyle(fontSize: 12.5)),
          const SizedBox(height: 6),
          for (final r in BotService.rules)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(r.icon),
              title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(r.subtitle, style: const TextStyle(fontSize: 12.5)),
              value: _rules[r.key] ?? false,
              onChanged: (v) => setState(() => _rules[r.key] = v),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _canCreate ? _create : null,
            child: _creating
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create bot & get API key'),
          ),
          const SizedBox(height: 8),
          const Text(
            'You get an API key to copy. NWisp does not host your bot — you run it wherever you like.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
