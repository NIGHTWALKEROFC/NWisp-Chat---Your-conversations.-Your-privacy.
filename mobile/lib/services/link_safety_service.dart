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
    if (_ipHost.hasMatch(host)) {
      return "This link goes to a raw numeric address instead of a normal web address — a common way to hide where a link really leads.";
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
