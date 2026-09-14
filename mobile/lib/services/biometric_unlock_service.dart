import 'package:local_auth/local_auth.dart';

/// Feature: biometric unlock for the app-wide PIN (Face ID/fingerprint).
/// Thin wrapper around local_auth — kept as its own service (rather than
/// folded into AppLockService) so AppLockService stays exactly what it
/// was: the one place that owns the real credential (the PIN hash) and
/// verifies it. This service never stores or checks anything itself —
/// it only asks the OS "is this the device owner?" and reports back a
/// yes/no, which AuthGate then treats as equivalent to a correct PIN.
class BiometricUnlockService {
  BiometricUnlockService._();
  static final _auth = LocalAuthentication();

  /// Whether this device even has usable biometrics enrolled right now
  /// (Face ID/fingerprint set up in the OS) — used to decide whether to
  /// even show the "Unlock with biometrics" toggle in Settings at all,
  /// and whether to auto-prompt on the PIN screen.
  static Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  /// Shows the native biometric prompt. Returns true only on a genuine
  /// successful match — any error, cancellation, or lockout (too many
  /// failed attempts) returns false, and the caller (AuthGate) falls
  /// back to asking for the PIN as normal. Never throws.
  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock NWisp',
        options: const AuthenticationOptions(
          biometricOnly: true, // never falls back to the OS's own device
          // passcode/pattern here — this app's own PIN screen is the
          // fallback, so there's no reason to let the phone's screen-lock
          // credential double as a second way into THIS app's lock too.
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
