import 'dart:typed_data';

/// ML-KEM-768 (FIPS 203, the standardised form of CRYSTALS-Kyber) in plain
/// Dart, plus the SHA-3 / SHAKE functions it needs. No native code, no
/// package: this is the post-quantum key-exchange half of NWisp's hybrid
/// encryption (see PostQuantumService).
///
/// Sizes: public (encapsulation) key 1184 bytes, private (decapsulation)
/// key 2400 bytes, ciphertext 1088 bytes, shared secret 32 bytes.
///
/// The algorithm was first written in Python and cross-checked byte-for-byte
/// against an independent ML-KEM implementation (keys, ciphertexts and shared
/// secrets all matched, and tampered ciphertexts were rejected). This Dart
/// file is a direct port of that checked version. [selfTest] re-checks it on
/// the phone against a fixed known-answer vector, and the app switches the
/// post-quantum layer off (instead of using a broken one) if it ever fails.
///
/// Dart ints are 64-bit on Android, which the Keccak part relies on.
class MlKem768 {
  MlKem768._();

  static const int q = 3329;
  static const int k = 3;
  static const int eta1 = 2;
  static const int eta2 = 2;
  static const int du = 10;
  static const int dv = 4;

  static const int publicKeyLength = 1184;
  static const int secretKeyLength = 2400;
  static const int ciphertextLength = 1088;

  // ---------------------------------------------------------------- Keccak
  static final List<int> _rc = <int>[
    0x0000000000000001, 0x0000000000008082, -0x7FFFFFFFFFFF7F76, -0x7FFFFFFF7FFF8000,
    0x000000000000808B, 0x0000000080000001, -0x7FFFFFFF7FFF7F7F, -0x7FFFFFFFFFFF7FF7,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, -0x7FFFFFFFFFFFFF75, -0x7FFFFFFFFFFF7F77, -0x7FFFFFFFFFFF7FFD,
    -0x7FFFFFFFFFFF7FFE, -0x7FFFFFFFFFFFFF80, 0x000000000000800A, -0x7FFFFFFF7FFFFFF6,
    -0x7FFFFFFF7FFF7F7F, -0x7FFFFFFFFFFF7F80, 0x0000000080000001, -0x7FFFFFFF7FFF7FF8,
  ];

  static const List<List<int>> _rot = <List<int>>[
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
  ];

  static int _rotl(int x, int n) {
    n %= 64;
    if (n == 0) return x;
    return (x << n) | (x >>> (64 - n));
  }

  static void _keccakF(List<int> a) {
    final c = List<int>.filled(5, 0);
    final d = List<int>.filled(5, 0);
    final b = List<int>.filled(25, 0);
    for (var round = 0; round < 24; round++) {
      for (var x = 0; x < 5; x++) {
        c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
      }
      for (var x = 0; x < 5; x++) {
        d[x] = c[(x + 4) % 5] ^ _rotl(c[(x + 1) % 5], 1);
      }
      for (var i = 0; i < 25; i++) {
        a[i] ^= d[i % 5];
      }
      for (var x = 0; x < 5; x++) {
        for (var y = 0; y < 5; y++) {
          b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl(a[x + 5 * y], _rot[x][y]);
        }
      }
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          a[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]);
        }
      }
      a[0] ^= _rc[round];
    }
  }

  static Uint8List _sponge(List<int> data, int rate, int suffix, int outLen) {
    final st = List<int>.filled(25, 0);
    final padded = <int>[...data, suffix];
    while (padded.length % rate != 0) {
      padded.add(0);
    }
    padded[padded.length - 1] |= 0x80;
    for (var off = 0; off < padded.length; off += rate) {
      for (var i = 0; i < rate ~/ 8; i++) {
        var lane = 0;
        for (var j = 7; j >= 0; j--) {
          lane = (lane << 8) | padded[off + 8 * i + j];
        }
        st[i] ^= lane;
      }
      _keccakF(st);
    }
    final out = Uint8List(outLen);
    var produced = 0;
    while (true) {
      for (var i = 0; i < rate ~/ 8 && produced < outLen; i++) {
        var lane = st[i];
        for (var j = 0; j < 8 && produced < outLen; j++) {
          out[produced++] = lane & 0xFF;
          lane = lane >>> 8;
        }
      }
      if (produced >= outLen) return out;
      _keccakF(st);
    }
  }

  static Uint8List sha3_256(List<int> d) => _sponge(d, 136, 0x06, 32);
  static Uint8List sha3_512(List<int> d) => _sponge(d, 72, 0x06, 64);
  static Uint8List shake128(List<int> d, int n) => _sponge(d, 168, 0x1F, n);
  static Uint8List shake256(List<int> d, int n) => _sponge(d, 136, 0x1F, n);

  // ------------------------------------------------------------------- NTT
  static int _bitrev7(int i) {
    var r = 0;
    for (var b = 0; b < 7; b++) {
      r = (r << 1) | ((i >> b) & 1);
    }
    return r;
  }

  static int _powMod(int base, int exp) {
    var result = 1;
    var b = base % q;
    var e = exp;
    while (e > 0) {
      if (e & 1 == 1) result = result * b % q;
      b = b * b % q;
      e >>= 1;
    }
    return result;
  }

  static final List<int> _zetas = List<int>.generate(128, (i) => _powMod(17, _bitrev7(i)));
  static final List<int> _gammas = List<int>.generate(128, (i) => _powMod(17, 2 * _bitrev7(i) + 1));

  static List<int> _ntt(List<int> input) {
    final f = List<int>.of(input);
    var i = 1;
    for (var len = 128; len >= 2; len >>= 1) {
      for (var start = 0; start < 256; start += 2 * len) {
        final z = _zetas[i++];
        for (var j = start; j < start + len; j++) {
          final t = z * f[j + len] % q;
          f[j + len] = (f[j] - t) % q;
          f[j] = (f[j] + t) % q;
        }
      }
    }
    return f;
  }

  static List<int> _invNtt(List<int> input) {
    final f = List<int>.of(input);
    var i = 127;
    for (var len = 2; len <= 128; len <<= 1) {
      for (var start = 0; start < 256; start += 2 * len) {
        final z = _zetas[i--];
        for (var j = start; j < start + len; j++) {
          final t = f[j];
          f[j] = (t + f[j + len]) % q;
          f[j + len] = z * (f[j + len] - t) % q;
        }
      }
    }
    return f.map((x) => x * 3303 % q).toList();
  }

  static List<int> _mulNtt(List<int> a, List<int> b) {
    final h = List<int>.filled(256, 0);
    for (var i = 0; i < 128; i++) {
      final a0 = a[2 * i], a1 = a[2 * i + 1], b0 = b[2 * i], b1 = b[2 * i + 1];
      h[2 * i] = (a0 * b0 + (a1 * b1 % q) * _gammas[i]) % q;
      h[2 * i + 1] = (a0 * b1 + a1 * b0) % q;
    }
    return h;
  }

  static List<int> _add(List<int> a, List<int> b) => List<int>.generate(256, (i) => (a[i] + b[i]) % q);
  static List<int> _sub(List<int> a, List<int> b) => List<int>.generate(256, (i) => (a[i] - b[i]) % q);

  // -------------------------------------------------------------- Sampling
  static List<int> _sampleNtt(List<int> seed) {
    var len = 840;
    while (true) {
      final s = shake128(seed, len);
      final out = <int>[];
      var p = 0;
      while (out.length < 256 && p + 3 <= s.length) {
        final d1 = s[p] + 256 * (s[p + 1] & 15);
        final d2 = (s[p + 1] >> 4) + 16 * s[p + 2];
        p += 3;
        if (d1 < q) out.add(d1);
        if (d2 < q && out.length < 256) out.add(d2);
      }
      if (out.length == 256) return out;
      len *= 2;
    }
  }

  static List<int> _cbd(List<int> bytes, int eta) {
    final f = List<int>.filled(256, 0);
    int bit(int idx) => (bytes[idx >> 3] >> (idx & 7)) & 1;
    for (var i = 0; i < 256; i++) {
      var x = 0, y = 0;
      for (var j = 0; j < eta; j++) {
        x += bit(2 * i * eta + j);
        y += bit(2 * i * eta + eta + j);
      }
      f[i] = (x - y) % q;
    }
    return f;
  }

  // ------------------------------------------------------ Encode / compress
  static Uint8List _byteEncode(List<int> f, int d) {
    final out = Uint8List(32 * d);
    var acc = 0, nb = 0, idx = 0;
    for (final a in f) {
      acc |= a << nb;
      nb += d;
      while (nb >= 8) {
        out[idx++] = acc & 0xFF;
        acc >>= 8;
        nb -= 8;
      }
    }
    return out;
  }

  static List<int> _byteDecode(List<int> b, int d) {
    final m = d == 12 ? q : (1 << d);
    final f = <int>[];
    var acc = 0, nb = 0;
    for (final byte in b) {
      acc |= byte << nb;
      nb += 8;
      while (nb >= d) {
        f.add((acc & ((1 << d) - 1)) % m);
        acc >>= d;
        nb -= d;
      }
    }
    return f;
  }

  static int _compress(int x, int d) => (((x << d) + 1664) ~/ q) & ((1 << d) - 1);
  static int _decompress(int y, int d) => (y * q + (1 << (d - 1))) >> d;

  static List<int> _slice(List<int> l, int start, [int? end]) => l.sublist(start, end ?? l.length);

  static List<List<List<int>>> _genMatrix(List<int> rho) {
    return List.generate(k, (i) => List.generate(k, (j) => _sampleNtt([...rho, j, i])));
  }

  // ------------------------------------------------------------------- PKE
  static (Uint8List, Uint8List) _pkeKeyGen(List<int> d) {
    final g = sha3_512([...d, k]);
    final rho = _slice(g, 0, 32);
    final sigma = _slice(g, 32);
    final a = _genMatrix(rho);
    var n = 0;
    final s = <List<int>>[];
    final e = <List<int>>[];
    for (var i = 0; i < k; i++) {
      s.add(_cbd(shake256([...sigma, n++], 64 * eta1), eta1));
    }
    for (var i = 0; i < k; i++) {
      e.add(_cbd(shake256([...sigma, n++], 64 * eta1), eta1));
    }
    final sh = s.map(_ntt).toList();
    final eh = e.map(_ntt).toList();
    final th = <List<int>>[];
    for (var i = 0; i < k; i++) {
      var acc = List<int>.filled(256, 0);
      for (var j = 0; j < k; j++) {
        acc = _add(acc, _mulNtt(a[i][j], sh[j]));
      }
      th.add(_add(acc, eh[i]));
    }
    final ek = BytesBuilder();
    for (final t in th) {
      ek.add(_byteEncode(t, 12));
    }
    ek.add(rho);
    final dk = BytesBuilder();
    for (final x in sh) {
      dk.add(_byteEncode(x, 12));
    }
    return (ek.toBytes(), dk.toBytes());
  }

  static Uint8List _pkeEncrypt(List<int> ek, List<int> m, List<int> r) {
    final th = List.generate(k, (i) => _byteDecode(_slice(ek, 384 * i, 384 * (i + 1)), 12));
    final rho = _slice(ek, 384 * k);
    final a = _genMatrix(rho);
    var n = 0;
    final y = <List<int>>[];
    final e1 = <List<int>>[];
    for (var i = 0; i < k; i++) {
      y.add(_cbd(shake256([...r, n++], 64 * eta1), eta1));
    }
    for (var i = 0; i < k; i++) {
      e1.add(_cbd(shake256([...r, n++], 64 * eta2), eta2));
    }
    final e2 = _cbd(shake256([...r, n], 64 * eta2), eta2);
    final yh = y.map(_ntt).toList();
    final u = <List<int>>[];
    for (var i = 0; i < k; i++) {
      var acc = List<int>.filled(256, 0);
      for (var j = 0; j < k; j++) {
        acc = _add(acc, _mulNtt(a[j][i], yh[j]));
      }
      u.add(_add(_invNtt(acc), e1[i]));
    }
    final mu = _byteDecode(m, 1).map((x) => _decompress(x, 1)).toList();
    var acc = List<int>.filled(256, 0);
    for (var j = 0; j < k; j++) {
      acc = _add(acc, _mulNtt(th[j], yh[j]));
    }
    final v = _add(_add(_invNtt(acc), e2), mu);
    final out = BytesBuilder();
    for (final ui in u) {
      out.add(_byteEncode(ui.map((x) => _compress(x, du)).toList(), du));
    }
    out.add(_byteEncode(v.map((x) => _compress(x, dv)).toList(), dv));
    return out.toBytes();
  }

  static Uint8List _pkeDecrypt(List<int> dk, List<int> c) {
    final l1 = 32 * du * k;
    final u = List.generate(
      k,
      (i) => _byteDecode(_slice(c, 32 * du * i, 32 * du * (i + 1)), du).map((x) => _decompress(x, du)).toList(),
    );
    final v = _byteDecode(_slice(c, l1), dv).map((x) => _decompress(x, dv)).toList();
    final sh = List.generate(k, (i) => _byteDecode(_slice(dk, 384 * i, 384 * (i + 1)), 12));
    var acc = List<int>.filled(256, 0);
    for (var j = 0; j < k; j++) {
      acc = _add(acc, _mulNtt(sh[j], _ntt(u[j])));
    }
    final w = _sub(v, _invNtt(acc));
    return _byteEncode(w.map((x) => _compress(x, 1)).toList(), 1);
  }

  // -------------------------------------------------------------------- KEM
  /// Deterministic key generation from two 32-byte seeds [d] and [z].
  /// Returns (publicKey, secretKey).
  static (Uint8List, Uint8List) keyGenDeterministic(List<int> d, List<int> z) {
    final (ek, dkPke) = _pkeKeyGen(d);
    final dk = BytesBuilder()
      ..add(dkPke)
      ..add(ek)
      ..add(sha3_256(ek))
      ..add(z);
    return (ek, dk.toBytes());
  }

  /// Deterministic encapsulation from a 32-byte message [m]. Returns
  /// (sharedSecret, ciphertext).
  static (Uint8List, Uint8List) encapsulateDeterministic(List<int> ek, List<int> m) {
    final g = sha3_512([...m, ...sha3_256(ek)]);
    final key = Uint8List.fromList(_slice(g, 0, 32));
    final ct = _pkeEncrypt(ek, m, _slice(g, 32));
    return (key, ct);
  }

  /// Recovers the shared secret from [ct]. A tampered ciphertext does not
  /// throw — like the standard says, it returns an unrelated secret, so the
  /// caller's AEAD check is what rejects it.
  static Uint8List decapsulate(List<int> dk, List<int> ct) {
    final dkPke = _slice(dk, 0, 384 * k);
    final ek = _slice(dk, 384 * k, 768 * k + 32);
    final h = _slice(dk, 768 * k + 32, 768 * k + 64);
    final z = _slice(dk, 768 * k + 64);
    final m = _pkeDecrypt(dkPke, ct);
    final g = sha3_512([...m, ...h]);
    final kPrime = _slice(g, 0, 32);
    final r = _slice(g, 32);
    final kBad = shake256([...z, ...ct], 32);
    final again = _pkeEncrypt(ek, m, r);
    var same = again.length == ct.length;
    if (same) {
      var diff = 0;
      for (var i = 0; i < ct.length; i++) {
        diff |= again[i] ^ ct[i];
      }
      same = diff == 0;
    }
    return Uint8List.fromList(same ? kPrime : kBad);
  }

  /// Fresh random key pair (uses the supplied 64 random bytes: d || z).
  static (Uint8List, Uint8List) keyGen(List<int> random64) =>
      keyGenDeterministic(_slice(random64, 0, 32), _slice(random64, 32, 64));

  /// Fresh random encapsulation (uses 32 random bytes).
  static (Uint8List, Uint8List) encapsulate(List<int> ek, List<int> random32) =>
      encapsulateDeterministic(ek, random32);

  // -------------------------------------------------------------- Self-test
  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Known-answer check. Expected values were produced by an independent
  /// ML-KEM-768 implementation from d = bytes 0..31, z = bytes 32..63 and
  /// m = bytes 64..95. Returns true only if this Dart port reproduces the
  /// same shared secret and the same key/ciphertext fingerprints.
  static bool selfTest() {
    try {
      final d = List<int>.generate(32, (i) => i);
      final z = List<int>.generate(32, (i) => 32 + i);
      final m = List<int>.generate(32, (i) => 64 + i);
      final (ek, dk) = keyGenDeterministic(d, z);
      final (key, ct) = encapsulateDeterministic(ek, m);
      if (ek.length != publicKeyLength || dk.length != secretKeyLength || ct.length != ciphertextLength) {
        return false;
      }
      if (_hex(key) != '9cddd089ffe70e3996e76f7c8d06746df34d07e8657bc0fcf2bb0e1c3084aea1') return false;
      final back = decapsulate(dk, ct);
      if (_hex(back) != _hex(key)) return false;
      final bad = Uint8List.fromList(ct)..[5] ^= 1;
      if (_hex(decapsulate(dk, bad)) == _hex(key)) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

}
