import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/local_message.dart';
import '../../services/community_service.dart';
import '../../services/group_service.dart';
import '../../services/local_message_store.dart';
import '../../widgets/location_fields.dart';
import '../../widgets/mute_duration_sheet.dart';
import '../groups/group_chat_screen.dart';
import '../security/chat_pin_guard.dart';
import 'community_detail_screen.dart';
import 'community_widgets.dart';
import 'create_community_screen.dart';

enum _Sort { newest, biggest }

/// The "Community" tab: communities you have joined, plus a public
/// directory of every open community — searchable, filterable by topic and
/// by place (country → state → district). Unlike a normal group, a
/// community is NOT hidden: anyone using the app can find it here.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  static const _kCountry = 'community_filter_country';
  static const _kState = 'community_filter_state';
  static const _kDistrict = 'community_filter_district';

  final _search = TextEditingController();
  CommunityLocation _location = const CommunityLocation();
  String? _category;
  _Sort _sort = _Sort.newest;

  List<CommunityListing> _listings = [];
  bool _loading = true;
  String? _error;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _myCommunities = [];
  List<ConversationSummary> _summaries = [];
  StreamSubscription? _groupsSub;
  StreamSubscription? _summarySub;

  @override
  void initState() {
    super.initState();
    _groupsSub = GroupService.instance.myGroupsStream().listen((snap) {
      if (!mounted) return;
      setState(() => _myCommunities = snap.docs.where((d) => d.data()['isCommunity'] == true).toList());
    });
    _summarySub = LocalMessageStore.watchSummaries().listen((list) {
      if (mounted) setState(() => _summaries = list);
    });
    _restoreLocationAndLoad();
  }

  @override
  void dispose() {
    _groupsSub?.cancel();
    _summarySub?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _restoreLocationAndLoad() async {
    final prefs = await SharedPreferences.getInstance();
    _location = CommunityLocation(
      country: prefs.getString(_kCountry),
      state: prefs.getString(_kState),
      district: prefs.getString(_kDistrict),
    );
    await _load();
  }

  Future<void> _saveLocation() async {
    final prefs = await SharedPreferences.getInstance();
    Future<void> put(String k, String? v) => (v == null || v.isEmpty) ? prefs.remove(k) : prefs.setString(k, v);
    await put(_kCountry, _location.country);
    await put(_kState, _location.state);
    await put(_kDistrict, _location.district);
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final list = await CommunityService.instance.fetch(location: _location, category: _category);
      if (!mounted) return;
      setState(() {
        _listings = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().contains('permission-denied')
            ? "The database refused this. If you just installed this update, publish the new Firestore rules first (see the setup notes)."
            : "Couldn't load communities — check your connection and pull down to try again.";
      });
    }
  }

  List<CommunityListing> _visible() {
    final joined = _myCommunities.map((d) => d.id).toSet();
    final q = _search.text.trim().toLowerCase();
    final list = _listings.where((c) {
      if (joined.contains(c.id)) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.description.toLowerCase().contains(q) ||
          (c.category ?? '').toLowerCase().contains(q) ||
          c.location.label.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) {
      if (_sort == _Sort.biggest && a.memberCount != b.memberCount) return b.memberCount.compareTo(a.memberCount);
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  Future<void> _openLocationFilter() async {
    var temp = _location;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(sheetContext).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Filter by location', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                const SizedBox(height: 4),
                Text(
                  'Fill in as much as you like. Leave it all empty to see communities from everywhere.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(sheetContext).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                LocationFields(value: temp, onChanged: (v) => setSheetState(() => temp = v)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setSheetState(() => temp = const CommunityLocation()),
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: FilledButton(onPressed: () => Navigator.pop(sheetContext, true), child: const Text('Show communities'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied != true || !mounted) return;
    setState(() => _location = temp);
    await _saveLocation();
    await _load();
  }

  Future<void> _openCategoryFilter() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.apps),
                title: const Text('All topics'),
                trailing: _category == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheetContext, ''),
              ),
              for (final c in kCommunityCategories)
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: Text(c),
                  trailing: _category == c ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(sheetContext, c),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _category = picked.isEmpty ? null : picked);
    await _load();
  }

  Future<void> _create() async {
    final id = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const CreateCommunityScreen()));
    if (id == null || !mounted) return;
    await _load();
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: id)));
  }

  Future<void> _openMine(String groupId) async {
    if (!await requireChatPinIfLocked(context, groupId)) return;
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId)));
  }

  Future<void> _mineOptions(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final muted = GroupService.instance.isMutedByMe(doc.data());
    final name = (doc.data()['name'] as String?) ?? 'Community';
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
              title: Text(muted ? 'Unmute' : 'Mute…'),
              onTap: () => Navigator.pop(sheetContext, 'mute'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Community page'),
              onTap: () => Navigator.pop(sheetContext, 'page'),
            ),
            ListTile(
              leading: Icon(Icons.exit_to_app, color: Theme.of(sheetContext).colorScheme.error),
              title: Text('Leave $name', style: TextStyle(color: Theme.of(sheetContext).colorScheme.error)),
              onTap: () => Navigator.pop(sheetContext, 'leave'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action == 'mute') {
        if (muted) {
          await GroupService.instance.setMuted(doc.id, false);
        } else {
          final choice = await showMuteDurationSheet(context);
          if (choice == null) return;
          if (choice.isForever) {
            await GroupService.instance.setMuted(doc.id, true);
          } else {
            await GroupService.instance.muteFor(doc.id, choice.duration!);
          }
        }
      } else if (action == 'page') {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => CommunityDetailScreen(listing: _fromGroupDoc(doc))));
      } else if (action == 'leave') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Leave $name?'),
            content: const Text('You will stop receiving its messages, and the copy on this phone is removed.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Leave')),
            ],
          ),
        );
        if (ok == true) await CommunityService.instance.leave(doc.id);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("That didn't work — check your connection and try again.")));
    }
  }

  /// A minimal listing built from my own group document, used to open the
  /// community page for a community I have already joined.
  CommunityListing _fromGroupDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    return CommunityListing(
      id: doc.id,
      name: (d['name'] as String?) ?? 'Community',
      description: (d['description'] as String?) ?? '',
      category: null,
      rules: '',
      avatarUrl: d['avatarUrl'] as String?,
      ownerId: (d['ownerId'] as String?) ?? '',
      location: const CommunityLocation(),
      memberCount: List<String>.from(d['members'] ?? const []).length,
      maxMembers: (d['maxMembers'] as num?)?.toInt() ?? CommunityService.defaultMaxMembers,
      onlyAdminsCanSend: (d['onlyAdminsCanSend'] as bool?) ?? false,
      isActive: true,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Widget _mineTile(ColorScheme scheme, QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final name = (d['name'] as String?) ?? 'Community';
    ConversationSummary? summary;
    for (final s in _summaries) {
      if (s.conversationId == doc.id) summary = s;
    }
    final unread = summary?.unreadCount ?? 0;
    final muted = GroupService.instance.isMutedByMe(d);
    return ListTile(
      leading: CommunityAvatar(url: d['avatarUrl'] as String?, radius: 24),
      title: Text(name, style: unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null),
      subtitle: Text(
        summary?.lastText ?? ((d['description'] as String?)?.trim().isNotEmpty == true ? (d['description'] as String).trim() : 'Say hi 👋'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (muted) Icon(Icons.notifications_off, size: 16, color: scheme.onSurfaceVariant),
          if (unread > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: CircleAvatar(
                radius: 11,
                backgroundColor: scheme.primary,
                child: Text('$unread', style: TextStyle(fontSize: 11, color: scheme.onPrimary, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
      onTap: () => _openMine(doc.id),
      onLongPress: () => _mineOptions(doc),
    );
  }

  Widget _listingCard(ColorScheme scheme, CommunityListing c) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => CommunityDetailScreen(listing: c)));
          if (mounted) _load();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommunityAvatar(url: c.avatarUrl, radius: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                    if (c.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(c.description.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                    ],
                    const SizedBox(height: 8),
                    CommunityFacts(listing: c),
                  ],
                ),
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
    final visible = _visible();
    final searching = _search.text.trim().isNotEmpty;
    final filtersOn = !_location.isEmpty || _category != null;
    final mineSorted = [..._myCommunities]
      ..sort((a, b) {
        DateTime? at(String id) {
          for (final s in _summaries) {
            if (s.conversationId == id) return s.lastAt;
          }
          return null;
        }

        final aa = at(a.id) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bb = at(b.id) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bb.compareTo(aa);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Community')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search communities',
                  suffixIcon: searching
                      ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _search.clear()))
                      : null,
                ),
              ),
            ),
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      avatar: const Icon(Icons.place_outlined, size: 18),
                      label: Text(_location.isEmpty ? 'Anywhere' : _location.label),
                      onPressed: _openLocationFilter,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      avatar: const Icon(Icons.label_outline, size: 18),
                      label: Text(_category ?? 'All topics'),
                      onPressed: _openCategoryFilter,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      avatar: const Icon(Icons.sort, size: 18),
                      label: Text(_sort == _Sort.newest ? 'Newest' : 'Most members'),
                      onPressed: () => setState(() => _sort = _sort == _Sort.newest ? _Sort.biggest : _Sort.newest),
                    ),
                  ),
                  if (filtersOn)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ActionChip(
                        avatar: const Icon(Icons.filter_alt_off_outlined, size: 18),
                        label: const Text('Clear filters'),
                        onPressed: () async {
                          setState(() {
                            _location = const CommunityLocation();
                            _category = null;
                          });
                          await _saveLocation();
                          await _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
            if (mineSorted.isNotEmpty && !searching) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                child: Text('Your communities', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
              ),
              for (final d in mineSorted) _mineTile(scheme, d),
              const Divider(height: 24),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: Text(
                filtersOn && !_location.isEmpty ? 'Discover · ${_location.label}' : 'Discover communities',
                style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary),
              ),
            ),
            if (_loading)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 48, color: scheme.error),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _load, child: const Text('Try again')),
                  ],
                ),
              )
            else if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.groups_2_outlined, size: 64, color: scheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    Text(
                      filtersOn || searching ? 'No communities match' : 'No communities yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      filtersOn || searching
                          ? 'Try a different search, or clear the filters.'
                          : 'Be the first — tap Create to start one for your area or interest.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else
              for (final c in visible) _listingCard(scheme, c),
          ],
        ),
      ),
    );
  }
}
