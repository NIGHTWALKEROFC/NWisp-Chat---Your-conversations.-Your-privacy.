/// Feature: in-app scam/phishing link warning. Deliberately simple and
/// entirely on-device — no network calls, no external blocklist lookups
/// (which would mean sending every link someone receives to a third
/// party, itself a privacy leak in a supposedly zero-knowledge chat
/// app). This is a heuristic tripwire, not a guarantee: it catches
/// common, low-effort red flags (raw IP addresses instead of a domain,
/// a login-sounding subdomain paired with a completely different base
/// domain, punycode/lookalike characters, and a short list of
/// known-for-abuse link-shortener domains whose real destination is
/// hidden until you click) — it will not catch every real phishing link,
/// and it will occasionally flag a legitimate one. It exists to make
/// someone pause and look at the actual domain before tapping, not to
/// silently block anything.
class LinkSafetyService {
  LinkSafetyService._();

  static final RegExp urlPattern = RegExp(
    r'((?:https?:\/\/)[^\s]+)',
    caseSensitive: false,
  );

  static final Set<String> _shortenerDomains = {
    'bit.ly', 'tinyurl.com', 'goo.gl', 't.co', 'ow.ly', 'is.gd', 'buff.ly',
    'cutt.ly', 'rebrand.ly', 'shorturl.at', 'rb.gy',
  };

  static final RegExp _ipHost = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  static final RegExp _loginLookingSubdomain =
      RegExp(r'^(login|signin|secure|account|verify|update|support)\.', caseSensitive: false);

  // Feature: stronger checks (still entirely on this phone).
  static final Set<String> _riskyTlds = {'zip', 'mov', 'tk', 'ml', 'ga', 'cf', 'gq', 'click', 'country', 'kim', 'support'};
  static final RegExp _dangerousFile =
      RegExp(r'\.(apk|apks|xapk|exe|scr|bat|cmd|msi|jar|vbs|ps1|dmg|pkg|iso)(\?|#|$)', caseSensitive: false);

  /// Brand name → the real web addresses that belong to it. A link that
  /// MENTIONS a brand but is not on one of these is a classic phishing trick.
  static final Map<String, Set<String>> _brands = {
    'google': {'google.com', 'google.co.in', 'googleapis.com', 'goo.gl', 'gstatic.com', 'youtube.com', 'gmail.com'},
    'paypal': {'paypal.com', 'paypal.me'},
    'whatsapp': {'whatsapp.com', 'whatsapp.net', 'wa.me'},
    'instagram': {'instagram.com'},
    'facebook': {'facebook.com', 'fb.com', 'fb.me'},
    'telegram': {'telegram.org', 't.me', 'telegram.me'},
    'amazon': {'amazon.com', 'amazon.in', 'amzn.to', 'amzn.in'},
    'microsoft': {'microsoft.com', 'live.com', 'office.com', 'outlook.com'},
    'apple': {'apple.com', 'icloud.com'},
    'netflix': {'netflix.com'},
    'paytm': {'paytm.com'},
    'phonepe': {'phonepe.com'},
    'sbi': {'sbi.co.in', 'onlinesbi.sbi', 'sbi.bank.in'},
    'hdfc': {'hdfcbank.com'},
    'icici': {'icicibank.com'},
    'flipkart': {'flipkart.com'},
    'nwisp': {'nwisp.app'},
  };

  static const _twoPartSuffixes = {'co.in', 'co.uk', 'com.au', 'org.in', 'net.in', 'gov.in', 'ac.in', 'co.jp', 'com.br'};

  /// The "main" address of a host: the last two parts (three for co.in etc).
  static String registrable(String host) {
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    final lastTwo = parts.sublist(parts.length - 2).join('.');
    if (_twoPartSuffixes.contains(lastTwo) && parts.length >= 3) return parts.sublist(parts.length - 3).join('.');
    return lastTwo;
  }

  /// 0 = nothing odd, 1 = be careful, 2 = very likely a scam or harmful.
  static int level(String url) {
    final reason = flagReason(url);
    if (reason == null) return 0;
    return _highSignals.any((s) => reason.startsWith(s)) ? 2 : 1;
  }

  static const _highSignals = [
    'This link pretends',
    'This link hides',
    'This link downloads',
    'This link goes to a raw',
  ];

  static String hostOf(String url) {
    try {
      return Uri.parse(url).host.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// A short, human-readable reason this link was flagged, or null if
  /// nothing about it looked off. Deliberately at most one reason —
  /// piling on every matching heuristic in the warning text would just
  /// make it read as noise.
  static String? flagReason(String url) {
    final host = hostOf(url);
    if (host.isEmpty) return null;
    // Text in front of an "@" is ignored by browsers — scammers use it to
    // make a link LOOK like it goes to a trusted site.
    final authority = url.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '').split(RegExp(r'[/?#]')).first;
    if (authority.contains('@')) {
      return "This link hides its real destination: everything before the \"@\" is a decoy, the site is actually $host.";
    }
    if (_ipHost.hasMatch(host)) {
      return "This link goes to a raw numeric address instead of a normal web address — a common way to hide where a link really leads.";
    }
    if (_dangerousFile.hasMatch(Uri.tryParse(url)?.path ?? url)) {
      return "This link downloads a program file. Installing apps from links is a common way phones get infected.";
    }
    final main = registrable(host);
    // Whole words only ("paypal-login.xyz" counts, "pineapple.com" doesn't).
    final words = host.split(RegExp(r'[.\-]')).toSet();
    for (final entry in _brands.entries) {
      if (words.contains(entry.key) && !entry.value.contains(main)) {
        return "This link pretends to be ${entry.key[0].toUpperCase()}${entry.key.substring(1)}, but it goes to $main — which is not theirs.";
      }
    }
    final tld = host.split('.').last;
    if (_riskyTlds.contains(tld)) {
      return "Addresses ending in \".$tld\" are often used for scams — check that this is where you expect to go.";
    }
    if (host.split('.').length >= 5) {
      return "This address has an unusually long chain of parts — a common way to hide the real site at the end.";
    }
    if (url.toLowerCase().startsWith('http://')) {
      return "This link isn't encrypted (http, not https). Anything you type there can be read by others.";
    }
    if (_shortenerDomains.contains(host)) {
      return "This is a shortened link — it can redirect anywhere, and the real destination isn't visible until you tap it.";
    }
    if (_loginLookingSubdomain.hasMatch(host)) {
      return "This link's address starts with a word like \"login\" or \"secure\" but that alone doesn't confirm which real company it belongs to.";
    }
    if (host.contains('xn--')) {
      return "This web address uses characters that can visually imitate a well-known site's real address.";
    }
    return null;
  }

  static bool isSuspicious(String url) => flagReason(url) != null;
}
