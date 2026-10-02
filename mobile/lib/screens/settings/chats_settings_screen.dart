import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/home_sections_service.dart';
import '../../services/nearby_service.dart';
import '../../services/settings_service.dart';
import 'paused_chats_screen.dart';

const _ttlOptions = [0, 1, 6, 24, 72, 168]; // 0 = never auto-delete (the default)

/// Feature: settings reorganized into WhatsApp-style category pages.
/// General chat-list and messaging behavior — how the home screen is
/// organized, default auto-delete, paused chats, and whether you stay
/// signed in — pulled out of the old flat settings_screen.dart list.
class ChatsSettingsScreen extends StatefulWidget {
  const ChatsSettingsScreen({super.key});

  @override
  State<ChatsSettingsScreen> createState() => _ChatsSettingsScreenState();
}

class _ChatsSettingsScreenState extends State<ChatsSettingsScreen> {
  final _authService = AuthService();
  bool _stayLoggedIn = true;
  bool _separateGroupsAndChats = false;
  int _ttlHours = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stay = await SettingsService.getStayLoggedIn();
    final separateGroupsAndChats = await SettingsService.getSeparateGroupsAndChats();
    final privateDoc = await _authService.currentUserPrivateProfile();
    final privateData = privateDoc.data() ?? {};
    if (!mounted) return;
    setState(() {
      _stayLoggedIn = stay;
      _separateGroupsAndChats = separateGroupsAndChats;
      _ttlHours = (privateData['messageTtlHours'] as num?)?.toInt() ?? 0;
      _loading = false;
    });
  }

  void _openTtlPicker() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Auto-delete messages after', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Off by default — your messages stay on this phone until you delete them yourself. "
                  "Turning this on here sets the app-wide default; any single chat can still override it "
                  "from that chat's settings.",
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ),
            for (final hours in _ttlOptions)
              RadioListTile<int>(
                value: hours,
                groupValue: _ttlHours,
                title: Text(_ttlLabel(hours)),
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _ttlHours = value);
                  await _authService.updateMessageTtl(value);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _ttlLabel(int hours) {
    if (hours == 0) return 'Never';
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.call_split_outlined),
                  title: const Text('Separate chats and groups'),
                  subtitle: const Text('Show direct chats and groups as separate tabs on the home screen'),
                  value: _separateGroupsAndChats,
                  onChanged: (v) async {
                    setState(() => _separateGroupsAndChats = v);
                    await SettingsService.setSeparateGroupsAndChats(v);
                  },
                ),
                // Feature: home sections (bottom bar). Both can be switched off
                // to keep the home screen as clean as you like.
                ValueListenableBuilder<bool>(
                  valueListenable: HomeSectionsService.announcementsTab,
                  builder: (context, on, _) => SwitchListTile.adaptive(
                    secondary: const Icon(Icons.campaign_outlined),
                    title: const Text('Announcements section'),
                    subtitle: const Text(
                      'Keep announcement-only groups in their own tab, out of Chats. Off = they appear in Chats like any other group. '
                      'You can also mute or exit any of them from that tab.',
                    ),
                    value: on,
                    onChanged: (v) => HomeSectionsService.setAnnouncementsTab(v),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: HomeSectionsService.communityTab,
                  builder: (context, on, _) => SwitchListTile.adaptive(
                    secondary: const Icon(Icons.groups_2_outlined),
                    title: const Text('Community section'),
                    subtitle: const Text('Show the Community tab — find and join public communities near you or by topic. Off hides the tab — communities you joined then appear in Chats instead.'),
                    value: on,
                    onChanged: (v) => HomeSectionsService.setCommunityTab(v),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: HomeSectionsService.nearbyTab,
                  builder: (context, on, _) => SwitchListTile.adaptive(
                    secondary: const Icon(Icons.bluetooth_searching_rounded),
                    title: const Text('Nearby chat section'),
                    subtitle: const Text('Show the Nearby tab — chat with people close to you over Bluetooth and Wi-Fi, with no internet. Off hides the tab and stops any scanning.'),
                    value: on,
                    onChanged: (v) {
                      HomeSectionsService.setNearbyTab(v);
                      if (!v) NearbyService.instance.reset();
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Auto-delete messages'),
                  subtitle: Text(_ttlHours == 0 ? 'Off — messages stay until you delete them' : 'After ${_ttlLabel(_ttlHours)} (app-wide default)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openTtlPicker,
                ),
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('Paused chats'),
                  subtitle: const Text('See and end any mutually paused conversations early'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PausedChatsScreen()),
                  ),
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.lock_clock_outlined),
                  title: const Text('Stay signed in'),
                  subtitle: const Text('Off = sign in again every time you open the app'),
                  value: _stayLoggedIn,
                  onChanged: (v) async {
                    setState(() => _stayLoggedIn = v);
                    await SettingsService.setStayLoggedIn(v);
                  },
                ),
              ],
            ),
    );
  }
}
