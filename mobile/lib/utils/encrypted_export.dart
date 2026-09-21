import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

/// Feature: password-protected data export. Turns the plain "Export
/// your data" JSON file into one that's worthless without the password
/// the person chose at export time — so if the file ends up somewhere
/// it shouldn't (an email attachment, a cloud backup, a shared
/// computer), it's just unreadable ciphertext.
///
/// Uses PBKDF2-SHA256 (210,000 iterations — OWASP's current minimum
/// recommendation as of this writing) to turn the password into an
/// AES-256-GCM key, using the SAME `cryptography` package already used
/// elsewhere in this app (see CryptoService) — no new dependency.
///
/// The output is a small, self-describing JSON wrapper — a standard,
/// documented format (PBKDF2 + AES-GCM, both described right in the
/// file), not a proprietary one, so it stays decryptable with any
/// standard crypto library even without this app, as long as the
/// password is remembered.
class EncryptedExport {
  static const _iterations = 210000;
  static const _format = 'nwisp-encrypted-export-v1';
  static final _aesGcm = AesGcm.with256bits();
  static final _pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _iterations, bits: 256);

  static List<int> _randomBytes(int n) {
    final rand = Random.secure();
    return List<int>.generate(n, (_) => rand.nextInt(256));
  }

  /// Encrypts [plaintext] under [password]. Returns a JSON string ready
  /// to write straight to the export file.
  static Future<String> encrypt(String plaintext, String password) async {
    final salt = _randomBytes(16);
    final secretKey = await _pbkdf2.deriveKeyFromPassword(password: password, nonce: salt);
    final nonce = _randomBytes(12);
    final box = await _aesGcm.encrypt(utf8.encode(plaintext), secretKey: secretKey, nonce: nonce);
    final combined = [...box.cipherText, ...box.mac.bytes];
    final wrapper = {
      'format': _format,
      'kdf': 'pbkdf2-sha256',
      'iterations': _iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(combined),
    };
    return const JsonEncoder.withIndent('  ').convert(wrapper);
  }

  /// The reverse of [encrypt] — not currently wired into any screen (the
  /// export is a one-way "take your data out" feature), but provided so
  /// the person isn't stuck if they ever need to read their own export
  /// back, and so this class documents its own format executably rather
  /// than only in comments.
  static Future<String> decrypt(String wrapperJson, String password) async {
    final wrapper = jsonDecode(wrapperJson) as Map<String, dynamic>;
    if (wrapper['format'] != _format) throw Exception('Not an NWisp encrypted export file.');
    final salt = base64Decode(wrapper['salt'] as String);
    final nonce = base64Decode(wrapper['nonce'] as String);
    final combined = base64Decode(wrapper['ciphertext'] as String);
    final secretKey = await _pbkdf2.deriveKeyFromPassword(password: password, nonce: salt);
    final cipherBytes = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final box = SecretBox(cipherBytes, nonce: nonce, mac: Mac(macBytes));
    final clear = await _aesGcm.decrypt(box, secretKey: secretKey);
    return utf8.decode(clear);
  }
}
