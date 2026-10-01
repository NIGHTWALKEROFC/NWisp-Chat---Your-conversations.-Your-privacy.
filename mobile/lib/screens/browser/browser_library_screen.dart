import 'package:flutter/material.dart';
import '../../services/browser_data_service.dart';
import '../../services/browser_settings_service.dart';

/// Bookmarks and history. Tapping an entry closes this screen and returns
/// its address, so the browser can open it (when launched from the browser).
class BrowserLibraryScreen extends StatefulWidget {
  const BrowserLibraryScreen({super.key});

  @override
  State<BrowserLibraryScreen> createState() => _BrowserLibraryScreenState();
}

class _BrowserLibraryScreenState extends State<BrowserLibraryScreen> {
  final data = BrowserDataService.instance;
  List<BrowserEntry> _bookmarks = [];
  List<BrowserEntry> _history = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await BrowserSettingsService.instance.load();
    final b = await data.bookmarks();
    final h = await data.history();
    if (!mounted) return;
    setState(() {
      _bookmarks = List.of(b);
      _history = List.of(h);
      _loaded = true;
    });
  }

  String _host(String url) => Uri.tryParse(url)?.host ?? url;

  Widget _list(List<BrowserEntry> items, {required bool history}) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            history
                ? (BrowserSettingsService.instance.saveHistory.value
                    ? 'No history yet.'
                    : 'History is off. Turn on "Save browsing history" in Browser settings if you want it.')
                : 'No bookmarks yet. Open the ⋯ menu in the browser and choose "Add bookmark".',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final e = items[i];
        return Dismissible(
          key: ValueKey('${e.url}${e.ms}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) async {
            if (history) {
              await data.removeHistory(e.url, e.ms);
              _history.removeWhere((h) => h.url == e.url && h.ms == e.ms);
            } else {
              await data.removeBookmark(e.url);
              _bookmarks.removeWhere((b) => b.url == e.url);
            }
          },
          child: ListTile(
            leading: Icon(history ? Icons.history_rounded : Icons.bookmark_rounded),
            title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_host(e.url), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(context, e.url),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bookmarks & history'),
          bottom: const TabBar(tabs: [Tab(text: 'Bookmarks'), Tab(text: 'History')]),
          actions: [
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                await data.clearHistory();
                if (mounted) setState(() => _history = []);
              },
            ),
          ],
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [_list(_bookmarks, history: false), _list(_history, history: true)]),
      ),
    );
  }
}
