import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Builds a human-comparable "safety number" (Signal's term) / "security
/// code" (WhatsApp's term) from two people's Signal Protocol identity
/// public keys. Two people who compare this number through a channel they
/// both trust (read aloud on a call, compared in person) and see it match
/// have direct evidence they're talking to each other with no one able to
/// sit in the middle undetected — the number is derived entirely from
/// both sides' long-term identity keys, which never leave a device except
/// as this public value.
///
/// This is a from-scratch, simplified derivation (iterated SHA-256 over
/// the two (uid, identityKey) pairs, sorted by uid), not a byte-for-byte
/// port of Signal's own fingerprint algorithm — but it has the property
/// that actually matters for trust here: it's symmetric (both sides
/// compute the exact same digits no matter who's "me" and who's "them",
/// since the inputs are sorted by uid before hashing) and it changes
/// completely if either identity key changes, which is exactly what
/// SignalSessionService's IdentityChangedException already separately
/// warns about when it happens.
class SafetyNumberService {
  SafetyNumberService._();

  /// Matches Signal's own iteration count for its fingerprint derivation
  /// — not required for correctness here (any reasonably large fixed
  /// count works), but there's no reason to pick a different one.
  static const _iterations = 5200;
  static const _groupCount = 12;
  static const _digitsPerGroup = 5;

  /// Returns 12 space-separated 5-digit groups (60 digits total) — the
  /// same shape Signal's own safety number takes, which people who've
  /// used Signal before will already recognize.
  static Future<String> compute({
    required String uidA,
    required Uint8List keyA,
    required String uidB,
    required Uint8List keyB,
  }) async {
    final aFirst = uidA.compareTo(uidB) <= 0;
    final firstUid = aFirst ? uidA : uidB;
    final firstKey = aFirst ? keyA : keyB;
    final secondUid = aFirst ? uidB : uidA;
    final secondKey = aFirst ? keyB : keyA;

    final seedBytes = Uint8List.fromList([
      ...utf8.encode(firstUid),
      ...firstKey,
      ...utf8.encode(secondUid),
      ...secondKey,
    ]);

    final hasher = Sha256();
    var digest = Uint8List.fromList((await hasher.hash(seedBytes)).bytes);
    for (var i = 1; i < _iterations; i++) {
      digest = Uint8List.fromList((await hasher.hash(digest)).bytes);
    }

    // Derive 12 independent 5-digit groups from the final digest by
    // re-hashing it with a distinct counter each time, so every group
    // draws on the whole digest rather than just slicing it into pieces.
    final groups = <String>[];
    for (var g = 0; g < _groupCount; g++) {
      final roundInput = Uint8List.fromList([...digest, g]);
      final roundHash = (await hasher.hash(roundInput)).bytes;
      var value = 0;
      for (var i = 0; i < 4; i++) {
        value = (value << 8) | roundHash[i];
      }
      value = value.abs() % 100000;
      groups.add(value.toString().padLeft(_digitsPerGroup, '0'));
    }
    return groups.join(' ');
  }
}
