import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../services/browser_data_service.dart';
import '../../services/browser_settings_service.dart';
import 'browser_library_screen.dart';
import 'browser_settings_screen.dart';

/// Hosts that are well-known trackers / ad networks. Blocked for the main
/// page navigation, and (through the injected script below) for scripts,
/// images, frames, XHR/fetch and beacons the page tries to load.
const List<String> kTrackerHosts = [
  'google-analytics.com', 'googletagmanager.com', 'googletagservices.com', 'googlesyndication.com',
  'doubleclick.net', 'adservice.google.com', 'facebook.net', 'connect.facebook.net', 'graph.facebook.com',
  'analytics.twitter.com', 'ads-twitter.com', 'ads.linkedin.com', 'px.ads.linkedin.com', 'snap.licdn.com',
  'hotjar.com', 'static.hotjar.com', 'mixpanel.com', 'segment.io', 'segment.com', 'amplitude.com',
  'fullstory.com', 'clarity.ms', 'scorecardresearch.com', 'quantserve.com', 'criteo.com', 'criteo.net',
  'taboola.com', 'outbrain.com', 'adnxs.com', 'rubiconproject.com', 'pubmatic.com', 'openx.net',
  'adsrvr.org', 'moatads.com', 'chartbeat.com', 'newrelic.com', 'nr-data.net', 'optimizely.com',
  'branch.io', 'appsflyer.com', 'adjust.com', 'onesignal.com', 'yandex.ru/metrika', 'mc.yandex.ru',
  'tiktok.com/analytics', 'analytics.tiktok.com', 'bat.bing.com', 'ads.yahoo.com', 'amazon-adsystem.com',
];

bool _isTrackerHost(String host) {
  final h = host.toLowerCase();
  for (final t in kTrackerHosts) {
    final bare = t.split('/').first;
    if (h == bare || h.endsWith('.$bare')) return true;
  }
  return false;
}

/// NWisp's private browser: opens links from chats without leaving the app.
///
/// Features: several tabs, bookmarks, optional history, tracker blocking.
///
/// Honest limits (also shown in Browser settings): it uses Android's system
/// WebView, so it can't match a full privacy browser like Brave. What it
/// does: nothing is remembered unless you turn history on or add a bookmark,
/// cookies and cache are cleared when you close it, third-party cookies are
/// refused, known trackers are blocked, http:// pages are upgraded to
/// https://, the page is told not to track (DNT + GPC), camera/microphone/
/// location requests from sites are denied, and searches go through a
/// privacy search engine.
class InAppBrowserScreen extends StatefulWidget {
  final String? initialUrl;
  const InAppBrowserScreen({super.key, this.initialUrl});

  @override
  State<InAppBrowserScreen> createState() => _InAppBrowserScreenState();
}

class _BTab {
  final int id;
  final WebViewController controller;
  String url = '';
  String title = '';
  int progress = 0;
  bool canBack = false;
  bool canForward = false;
  bool start = true;
  int blocked = 0;
  _BTab(this.id, this.controller);
}

class _InAppBrowserScreenState extends State<InAppBrowserScreen> {
  static const int _maxTabs = 8;
  final _settings = BrowserSettingsService.instance;
  final _data = BrowserDataService.instance;
  final _addressController = TextEditingController();
  final _addressFocus = FocusNode();
  final List<_BTab> _tabs = [];
  int _current = 0;
  int _nextId = 1;
  bool _ready = false;
  int _blockedSession = 0;
  bool _bookmarked = false;

  _BTab get _tab => _tabs[_current];

  static const _blockScript = r'''
(function(){
  if (window.__nwBlock) return; window.__nwBlock = true;
  var HOSTS = __HOSTS__;
  function bad(u){ try{ var h=new URL(u, location.href).hostname.toLowerCase();
    for (var i=0;i<HOSTS.length;i++){ if(h===HOSTS[i]||h.endsWith('.'+HOSTS[i])) return true; } }catch(e){} return false; }
  function note(){ try{ NWBlocked.postMessage('1'); }catch(e){} }
  var of = window.fetch; if (of) window.fetch = function(i,o){ var u=(typeof i==='string')?i:(i&&i.url); if(u&&bad(u)){note();return Promise.reject(new TypeError('blocked'));} return of.apply(this,arguments); };
  var ox = XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open = function(m,u){ if(bad(u)){ note(); u='about:blank'; } return ox.apply(this,arguments); };
  if (navigator.sendBeacon) { var ob = navigator.sendBeacon.bind(navigator); navigator.sendBeacon = function(u,d){ if(bad(u)){note();return true;} return ob(u,d); }; }
  function scrub(n){ if(!n||n.nodeType!==1) return; var t=n.tagName;
    if((t==='SCRIPT'||t==='IFRAME'||t==='IMG'||t==='LINK') && bad(n.src||n.href||'')){ note(); n.remove(); return; }
    if(n.querySelectorAll){ n.querySelectorAll('script[src],iframe[src],img[src]').forEach(function(x){ if(bad(x.src)){ note(); x.remove(); } }); } }
  new MutationObserver(function(ms){ ms.forEach(function(m){ m.addedNodes.forEach(scrub); }); }).observe(document.documentElement,{childList:true,subtree:true});
  try{ Object.defineProperty(navigator,'doNotTrack',{get:function(){return '1';}}); }catch(e){}
  try{ Object.defineProperty(navigator,'globalPrivacyControl',{get:function(){return true;}}); }catch(e){}
})();
''';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _settings.load();
    final first = await _newTab(select: false);
    _tabs.add(first);
    if (!mounted) return;
    setState(() => _ready = true);
    final start = widget.initialUrl;
    if (start != null && start.isNotEmpty) _go(start);
  }

  Future<_BTab> _newTab({bool select = true}) async {
    final controller = WebViewController();
    final tab = _BTab(_nextId++, controller);
    await controller.setJavaScriptMode(_settings.javascript.value ? JavaScriptMode.unrestricted : JavaScriptMode.disabled);
    await controller.setBackgroundColor(const Color(0xFF0B1024));
    await controller.setUserAgent(_settings.desktopMode.value
        ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        : 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36');
    await controller.addJavaScriptChannel('NWBlocked', onMessageReceived: (_) {
      if (!mounted) return;
      setState(() {
        tab.blocked++;
        _blockedSession++;
      });
    });
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) => _onNavigationRequest(tab, r),
      onPageStarted: (url) {
        if (!mounted) return;
        setState(() {
          tab.url = url;
          tab.progress = 5;
          tab.blocked = 0;
          tab.start = url == 'about:blank';
          if (identical(tab, _tabs.isEmpty ? null : _tab) && !_addressFocus.hasFocus) {
            _addressController.text = tab.start ? '' : url;
          }
        });
        if (_settings.blockTrackers.value) _injectBlocker(tab);
      },
      onProgress: (p) {
        if (mounted) setState(() => tab.progress = p);
      },
      onPageFinished: (url) async {
        if (_settings.blockTrackers.value) _injectBlocker(tab);
        final title = await controller.getTitle();
        final back = await controller.canGoBack();
        final fwd = await controller.canGoForward();
        if (!mounted) return;
        setState(() {
          tab.url = url;
          tab.title = title ?? '';
          tab.progress = 100;
          tab.canBack = back;
          tab.canForward = fwd;
        });
        if (url != 'about:blank' && _settings.saveHistory.value) {
          _data.addHistory(url, title ?? '');
        }
        if (identical(tab, _tab)) _refreshBookmarkState();
      },
      onWebResourceError: (e) {},
    ));
    await _hardenAndroid(controller);
    if (select) {
      _tabs.add(tab);
      if (mounted) {
        setState(() {
          _current = _tabs.length - 1;
          _addressController.clear();
          _bookmarked = false;
        });
      }
    }
    return tab;
  }

  /// Android-only extras. Kept in one small method: if a plugin update ever
  /// renames something here, deleting this method's body is safe.
  Future<void> _hardenAndroid(WebViewController controller) async {
    try {
      final platform = controller.platform;
      final cookieManager = WebViewCookieManager().platform;
      if (platform is AndroidWebViewController && cookieManager is AndroidWebViewCookieManager) {
        await cookieManager.setAcceptThirdPartyCookies(platform, !_settings.blockThirdPartyCookies.value);
      }
    } catch (_) {}
  }

  void _injectBlocker(_BTab tab) {
    final hosts = kTrackerHosts.map((h) => "'${h.split('/').first}'").join(',');
    tab.controller.runJavaScript(_blockScript.replaceFirst('__HOSTS__', '[$hosts]'));
  }

  NavigationDecision _onNavigationRequest(_BTab tab, NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'about') return NavigationDecision.navigate;
    if (scheme == 'http' && _settings.httpsOnly.value) {
      // Embedded (iframe) http content is simply refused; a page address is
      // upgraded to https instead of loading the unencrypted page.
      if (request.isMainFrame) _load(tab, uri.replace(scheme: 'https'));
      return NavigationDecision.prevent;
    }
    if (scheme != 'http' && scheme != 'https') {
      // tel:, mailto:, intent:, market: … — never launch other apps silently.
      _offerExternal(request.url);
      return NavigationDecision.prevent;
    }
    if (_settings.blockTrackers.value && _isTrackerHost(uri.host)) {
      setState(() {
        tab.blocked++;
        _blockedSession++;
      });
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _offerExternal(String url) async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open another app?'),
        content: Text('This page wants to open:\n\n${url.length > 120 ? '${url.substring(0, 120)}…' : url}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open')),
        ],
      ),
    );
    if (ok == true) {
      final u = Uri.tryParse(url);
      if (u != null) {
        try {
          await launchUrl(u, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
    }
  }

  /// Turns whatever was typed into a page address or a search.
  Uri _resolve(String input) {
    final text = input.trim();
    final looksLikeUrl = !text.contains(' ') && (text.contains('.') || text.startsWith('http')) && !text.endsWith('.');
    if (looksLikeUrl) {
      final withScheme = text.contains('://') ? text : 'https://$text';
      final u = Uri.tryParse(withScheme);
      if (u != null && u.host.isNotEmpty) return u;
    }
    return Uri.parse('${_settings.searchPrefix}${Uri.encodeQueryComponent(text)}');
  }

  void _load(_BTab tab, Uri uri) {
    setState(() => tab.start = false);
    // DNT / GPC on the main request as well (sub-requests are covered by the injected script).
    tab.controller.loadRequest(uri, headers: const {'DNT': '1', 'Sec-GPC': '1'});
  }

  void _go(String input) {
    if (input.trim().isEmpty || _tabs.isEmpty) return;
    var uri = _resolve(input);
    if (uri.scheme == 'http' && _settings.httpsOnly.value) uri = uri.replace(scheme: 'https');
    _load(_tab, uri);
  }

  Future<void> _refreshBookmarkState() async {
    if (_tabs.isEmpty) return;
    final url = _tab.url;
    final b = url.isNotEmpty && url != 'about:blank' && await _data.isBookmarked(url);
    if (mounted && b != _bookmarked) setState(() => _bookmarked = b);
  }

  Future<void> _wipe() async {
    try {
      if (_tabs.isEmpty) return;
      await _tabs.first.controller.clearCache();
      await _tabs.first.controller.clearLocalStorage();
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
  }

  @override
  void dispose() {
    _settings.addBlocked(_blockedSession);
    if (_ready && _settings.clearOnExit.value) _wipe();
    _addressController.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ tabs
  Future<void> _addTab() async {
    if (_tabs.length >= _maxTabs) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Up to 8 tabs at once.')));
      return;
    }
    await _newTab();
  }

  void _selectTab(int i) {
    setState(() {
      _current = i;
      _addressController.text = _tab.start ? '' : _tab.url;
    });
    _refreshBookmarkState();
  }

  void _closeTab(int i) {
    if (_tabs.length == 1) {
      // The last tab just goes back to the start page.
      _tab.controller.loadRequest(Uri.parse('about:blank'));
      setState(() {
        _tab.start = true;
        _tab.title = '';
        _tab.url = '';
        _addressController.clear();
      });
      return;
    }
    setState(() {
      _tabs.removeAt(i);
      if (_current >= _tabs.length) _current = _tabs.length - 1;
      _addressController.text = _tab.start ? '' : _tab.url;
    });
    _refreshBookmarkState();
  }

  void _showTabs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                  child: Row(children: [
                    Text('${_tabs.length} tab${_tabs.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _addTab();
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('New tab'),
                    ),
                  ]),
                ),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.5),
                    itemCount: _tabs.length,
                    itemBuilder: (_, i) {
                      final t = _tabs[i];
                      final selected = i == _current;
                      final scheme = Theme.of(ctx).colorScheme;
                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          Navigator.pop(ctx);
                          _selectTab(i);
                        },
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(t.start ? Icons.shield_moon_rounded : Icons.public, size: 16, color: scheme.primary),
                                const Spacer(),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () {
                                    _closeTab(i);
                                    if (_tabs.isEmpty) return;
                                    setSheet(() {});
                                  },
                                ),
                              ]),
                              const Spacer(),
                              Text(t.start ? 'New tab' : (t.title.isEmpty ? (Uri.tryParse(t.url)?.host ?? t.url) : t.title),
                                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                              if (!t.start)
                                Text(Uri.tryParse(t.url)?.host ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLibrary() async {
    final url = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const BrowserLibraryScreen()));
    if (url != null && mounted) _go(url);
  }

  Future<void> _toggleBookmark() async {
    final url = _tab.url;
    if (url.isEmpty || url == 'about:blank') return;
    final now = await _data.toggleBookmark(url, _tab.title);
    if (!mounted) return;
    setState(() => _bookmarked = now);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(now ? 'Bookmark added' : 'Bookmark removed')));
  }

  Future<void> _openExternally() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave NWisp?'),
        content: const Text(
          "This opens the page in your phone's default browser. That browser can keep history and cookies and may track you.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay here')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open anyway')),
        ],
      ),
    );
    if (ok == true) {
      final u = Uri.tryParse(_tab.url);
      if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
    }
  }

  void _menu() {
    final onPage = !_tab.start && _tab.url.isNotEmpty;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.add_box_outlined), title: const Text('New tab'), onTap: () {
                Navigator.pop(ctx);
                _addTab();
              }),
              if (onPage)
                ListTile(
                  leading: Icon(_bookmarked ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined),
                  title: Text(_bookmarked ? 'Remove bookmark' : 'Add bookmark'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleBookmark();
                  },
                ),
              ListTile(leading: const Icon(Icons.bookmarks_outlined), title: const Text('Bookmarks & history'), onTap: () {
                Navigator.pop(ctx);
                _openLibrary();
              }),
              if (onPage) ...[
                ListTile(leading: const Icon(Icons.refresh), title: const Text('Reload'), onTap: () {
                  Navigator.pop(ctx);
                  _tab.controller.reload();
                }),
                ListTile(leading: const Icon(Icons.link), title: const Text('Copy link'), onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: _tab.url));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                  // Clear it again after a minute so it doesn't linger.
                  Timer(const Duration(minutes: 1), () => Clipboard.setData(const ClipboardData(text: '')));
                }),
                ListTile(leading: const Icon(Icons.share_outlined), title: const Text('Share link'), onTap: () {
                  Navigator.pop(ctx);
                  Share.share(_tab.url);
                }),
                ListTile(leading: const Icon(Icons.open_in_browser), title: const Text('Open in default browser'), onTap: () {
                  Navigator.pop(ctx);
                  _openExternally();
                }),
              ],
              ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: const Text('Clear browsing data now'), onTap: () async {
                Navigator.pop(ctx);
                await _wipe();
                await _data.clearHistory();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cookies, cache, site data and history cleared')));
              }),
              ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('Browser settings'), onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserSettingsScreen()));
              }),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tab = _ready ? _tab : null;
    final secure = tab?.url.startsWith('https://') ?? false;
    final onStart = tab?.start ?? true;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (_ready && _tab.canBack && !_tab.start) {
          await _tab.controller.goBack();
        } else if (_ready && _tabs.length > 1) {
          _closeTab(_current);
        } else {
          nav.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Close browser', onPressed: () => Navigator.of(context).pop()),
          title: Container(
            height: 42,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(22)),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(onStart ? Icons.search : (secure ? Icons.lock_rounded : Icons.lock_open_rounded),
                    size: 17, color: onStart ? scheme.onSurfaceVariant : (secure ? Colors.green : scheme.error)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _addressController,
                    focusNode: _addressFocus,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    style: const TextStyle(fontSize: 14.5),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Search with ${_settings.searchName} or type a link',
                      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                    ),
                    onTap: () => _addressController.selection = TextSelection(baseOffset: 0, extentOffset: _addressController.text.length),
                    onSubmitted: (v) {
                      _addressFocus.unfocus();
                      _go(v);
                    },
                  ),
                ),
                if ((tab?.blocked ?? 0) > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Row(children: [
                      Icon(Icons.shield_rounded, size: 15, color: Colors.orange.shade400),
                      const SizedBox(width: 3),
                      Text('${tab!.blocked}', style: TextStyle(fontSize: 12, color: Colors.orange.shade400, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                if (!onStart)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: _bookmarked ? 'Remove bookmark' : 'Add bookmark',
                    icon: Icon(_bookmarked ? Icons.star_rounded : Icons.star_border_rounded, size: 20, color: _bookmarked ? Colors.amber : null),
                    onPressed: _toggleBookmark,
                  ),
              ],
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: (tab != null && tab.progress > 0 && tab.progress < 100)
                ? LinearProgressIndicator(value: tab.progress / 100, minHeight: 2)
                : const SizedBox(height: 2),
          ),
        ),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: _current,
                children: [
                  for (final t in _tabs)
                    Stack(
                      key: ValueKey('tab${t.id}'),
                      children: [
                        WebViewWidget(controller: t.controller),
                        if (t.start) Positioned.fill(child: _startPage(scheme)),
                      ],
                    ),
                ],
              ),
        bottomNavigationBar: !_ready
            ? null
            : BottomAppBar(
                height: 56,
                padding: EdgeInsets.zero,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: (_tab.canBack && !_tab.start) ? () => _tab.controller.goBack() : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: (_tab.canForward && !_tab.start) ? () => _tab.controller.goForward() : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.home_outlined),
                      onPressed: () async {
                        await _tab.controller.loadRequest(Uri.parse('about:blank'));
                        setState(() {
                          _tab.start = true;
                          _addressController.clear();
                          _tab.title = '';
                          _tab.url = '';
                          _bookmarked = false;
                        });
                      },
                    ),
                    // Tab switcher, with the number of open tabs.
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _showTabs,
                      child: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.8), borderRadius: BorderRadius.circular(7)),
                        child: Text('${_tabs.length}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.more_horiz_rounded), onPressed: _menu),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _startPage(ColorScheme scheme) {
    final defaults = <(String, String, IconData)>[
      ('Wikipedia', 'https://wikipedia.org', Icons.menu_book_rounded),
      ('DuckDuckGo', 'https://duckduckgo.com', Icons.travel_explore_rounded),
      ('Brave Search', 'https://search.brave.com', Icons.shield_moon_rounded),
      ('Maps', 'https://www.openstreetmap.org', Icons.map_rounded),
      ('News', 'https://news.ycombinator.com', Icons.newspaper_rounded),
      ('Weather', 'https://wttr.in', Icons.wb_sunny_rounded),
    ];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFF0B1024), scheme.surface],
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 34, 20, 24),
        children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [Color(0xFF38A8FF), Color(0xFF7C4DFF)]),
                boxShadow: [BoxShadow(color: const Color(0xFF38A8FF).withValues(alpha: 0.35), blurRadius: 28, spreadRadius: 2)],
              ),
              child: const Icon(Icons.shield_rounded, color: Colors.white, size: 42),
            ),
          ),
          const SizedBox(height: 18),
          const Center(child: Text('NWisp Private Browser', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800))),
          const SizedBox(height: 6),
          Center(
            child: Text('Nothing is remembered unless you choose to.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 13.5)),
          ),
          const SizedBox(height: 22),
          GestureDetector(
            onTap: () => _addressFocus.requestFocus(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(28)),
              child: Row(children: [
                const Icon(Icons.search, color: Colors.white70),
                const SizedBox(width: 12),
                Text('Search with ${_settings.searchName}', style: const TextStyle(color: Colors.white70, fontSize: 15)),
              ]),
            ),
          ),
          const SizedBox(height: 24),
          // Your bookmarks first (up to 6), then the built-in shortcuts.
          FutureBuilder<List<BrowserEntry>>(
            future: _data.bookmarks(),
            builder: (context, snap) {
              final marks = (snap.data ?? const <BrowserEntry>[]).take(6).toList();
              final tiles = <(String, String, IconData)>[
                for (final b in marks) (b.title, b.url, Icons.bookmark_rounded),
                if (marks.isEmpty) ...defaults,
              ];
              return GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.05,
                children: [
                  for (final q in tiles)
                    InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _go(q.$2),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(18)),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(q.$3, color: const Color(0xFF7CC4FF), size: 28),
                            const SizedBox(height: 8),
                            Text(q.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _perk(Icons.block_rounded, 'Known trackers and ads blocked'),
                _perk(Icons.cookie_outlined, 'Third-party cookies refused'),
                _perk(Icons.https_rounded, 'http:// pages upgraded to https://'),
                _perk(Icons.delete_outline_rounded, 'Cookies & cache wiped when you close it'),
                _perk(Icons.location_off_outlined, 'Camera, mic and location requests denied'),
                if (_settings.trackersBlockedTotal + _blockedSession > 0) ...[
                  const Divider(color: Colors.white12),
                  Text('${_settings.trackersBlockedTotal + _blockedSession} trackers blocked so far',
                      style: TextStyle(color: Colors.orange.shade300, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _perk(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(icon, size: 18, color: const Color(0xFF6EE7A8)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13))),
        ]),
      );
}

/// Opens [url] (or the start page) in NWisp's own browser.
Future<void> openInAppBrowser(BuildContext context, {String? url}) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => InAppBrowserScreen(initialUrl: url)));
}
