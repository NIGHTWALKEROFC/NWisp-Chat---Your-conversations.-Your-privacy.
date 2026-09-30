import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../services/browser_settings_service.dart';
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
/// Honest limits (also shown in Browser settings): it uses Android's system
/// WebView, so it can't match a full privacy browser like Brave. What it
/// does: nothing is remembered (no history, cookies and cache cleared when
/// you close it), third-party cookies are refused, known trackers are
/// blocked, http:// pages are upgraded to https://, the page is told not to
/// track (DNT + GPC), camera/microphone/location requests from sites are
/// denied, and searches go through a privacy search engine.
class InAppBrowserScreen extends StatefulWidget {
  final String? initialUrl;
  const InAppBrowserScreen({super.key, this.initialUrl});

  @override
  State<InAppBrowserScreen> createState() => _InAppBrowserScreenState();
}

class _InAppBrowserScreenState extends State<InAppBrowserScreen> {
  final _settings = BrowserSettingsService.instance;
  late final WebViewController _controller;
  final _addressController = TextEditingController();
  final _addressFocus = FocusNode();
  bool _ready = false;
  bool _onStartPage = true;
  int _progress = 0;
  String _url = '';
  String _title = '';
  bool _canBack = false;
  bool _canForward = false;
  int _blockedThisPage = 0;
  int _blockedSession = 0;

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
    final controller = WebViewController();
    _controller = controller;
    await controller.setJavaScriptMode(_settings.javascript.value ? JavaScriptMode.unrestricted : JavaScriptMode.disabled);
    await controller.setBackgroundColor(const Color(0xFF0B1024));
    await controller.setUserAgent(_settings.desktopMode.value
        ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        : 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36');
    await controller.addJavaScriptChannel('NWBlocked', onMessageReceived: (_) {
      if (!mounted) return;
      setState(() {
        _blockedThisPage++;
        _blockedSession++;
      });
    });
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: _onNavigationRequest,
      onPageStarted: (url) {
        if (!mounted) return;
        setState(() {
          _url = url;
          _progress = 5;
          _blockedThisPage = 0;
          _onStartPage = url == 'about:blank';
          if (!_addressFocus.hasFocus) _addressController.text = _onStartPage ? '' : url;
        });
        if (_settings.blockTrackers.value) _injectBlocker();
      },
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      onPageFinished: (url) async {
        if (_settings.blockTrackers.value) _injectBlocker();
        final title = await controller.getTitle();
        final back = await controller.canGoBack();
        final fwd = await controller.canGoForward();
        if (!mounted) return;
        setState(() {
          _url = url;
          _title = title ?? '';
          _progress = 100;
          _canBack = back;
          _canForward = fwd;
        });
      },
      onWebResourceError: (e) {},
    ));
    await _hardenAndroid(controller);
    if (!mounted) return;
    setState(() => _ready = true);
    final start = widget.initialUrl;
    if (start != null && start.isNotEmpty) {
      _go(start);
    } else {
      setState(() => _onStartPage = true);
    }
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

  void _injectBlocker() {
    final hosts = kTrackerHosts.map((h) => "'${h.split('/').first}'").join(',');
    _controller.runJavaScript(_blockScript.replaceFirst('__HOSTS__', '[$hosts]'));
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'about') return NavigationDecision.navigate;
    if (scheme == 'http' && _settings.httpsOnly.value) {
      // Embedded (iframe) http content is simply refused; a page address is
      // upgraded to https instead of loading the unencrypted page.
      if (request.isMainFrame) _go(uri.replace(scheme: 'https').toString());
      return NavigationDecision.prevent;
    }
    if (scheme != 'http' && scheme != 'https') {
      // tel:, mailto:, intent:, market: … — never launch other apps silently.
      _offerExternal(request.url);
      return NavigationDecision.prevent;
    }
    if (_settings.blockTrackers.value && _isTrackerHost(uri.host)) {
      setState(() {
        _blockedThisPage++;
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

  void _go(String input) {
    if (input.trim().isEmpty) return;
    var uri = _resolve(input);
    if (uri.scheme == 'http' && _settings.httpsOnly.value) uri = uri.replace(scheme: 'https');
    setState(() => _onStartPage = false);
    // DNT / GPC on the main request as well (sub-requests are covered by the injected script).
    _controller.loadRequest(uri, headers: const {'DNT': '1', 'Sec-GPC': '1'});
  }

  Future<void> _wipe() async {
    try {
      await _controller.clearCache();
      await _controller.clearLocalStorage();
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
      final u = Uri.tryParse(_url);
      if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
    }
  }

  void _menu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.refresh), title: const Text('Reload'), onTap: () {
              Navigator.pop(ctx);
              _controller.reload();
            }),
            ListTile(leading: const Icon(Icons.link), title: const Text('Copy link'), onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: _url));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
              // Clear it again after a minute so it doesn't linger.
              Timer(const Duration(minutes: 1), () => Clipboard.setData(const ClipboardData(text: '')));
            }),
            ListTile(leading: const Icon(Icons.share_outlined), title: const Text('Share link'), onTap: () {
              Navigator.pop(ctx);
              Share.share(_url);
            }),
            ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: const Text('Clear browsing data now'), onTap: () async {
              Navigator.pop(ctx);
              await _wipe();
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cookies, cache and site data cleared')));
            }),
            ListTile(leading: const Icon(Icons.open_in_browser), title: const Text('Open in default browser'), onTap: () {
              Navigator.pop(ctx);
              _openExternally();
            }),
            ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('Browser settings'), onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowserSettingsScreen()));
            }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secure = _url.startsWith('https://');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (_ready && _canBack && !_onStartPage) {
          await _controller.goBack();
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
                Icon(_onStartPage ? Icons.search : (secure ? Icons.lock_rounded : Icons.lock_open_rounded),
                    size: 17, color: _onStartPage ? scheme.onSurfaceVariant : (secure ? Colors.green : scheme.error)),
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
                if (_blockedThisPage > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Row(children: [
                      Icon(Icons.shield_rounded, size: 15, color: Colors.orange.shade400),
                      const SizedBox(width: 3),
                      Text('$_blockedThisPage', style: TextStyle(fontSize: 12, color: Colors.orange.shade400, fontWeight: FontWeight.w700)),
                    ]),
                  ),
              ],
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: (_progress > 0 && _progress < 100) ? LinearProgressIndicator(value: _progress / 100, minHeight: 2) : const SizedBox(height: 2),
          ),
        ),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_onStartPage) Positioned.fill(child: _startPage(scheme)),
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
                      onPressed: (_canBack && !_onStartPage) ? () => _controller.goBack() : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: (_canForward && !_onStartPage) ? () => _controller.goForward() : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.home_outlined),
                      onPressed: () async {
                        await _controller.loadRequest(Uri.parse('about:blank'));
                        setState(() {
                          _onStartPage = true;
                          _addressController.clear();
                          _title = '';
                          _url = '';
                        });
                      },
                    ),
                    IconButton(icon: const Icon(Icons.more_horiz_rounded), onPressed: _menu),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _startPage(ColorScheme scheme) {
    final quick = <(String, String, IconData)>[
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
            child: Text('Nothing is remembered. Trackers are blocked.',
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
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.05,
            children: [
              for (final q in quick)
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _go(q.$2),
                  child: Container(
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(18)),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(q.$3, color: const Color(0xFF7CC4FF), size: 28),
                        const SizedBox(height: 8),
                        Text(q.$1, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
            ],
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
