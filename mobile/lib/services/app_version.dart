/// The running app's own version number, filled in once at start-up
/// (IntegrityService.init) and sent to the server with media / role requests so
/// the server can enforce the minimum version (see _shared/version_gate.ts).
class AppVersion {
  AppVersion._();

  static int code = 0;
  static String name = '';

  /// Extra HTTP headers that carry the version.
  static Map<String, String> get headers => {'x-app-version': '$code'};
}
