import 'dart:typed_data';

/// The SHA-256 digest of [message].
///
/// FIPS 180-4, in the few dozen lines it takes. Here rather than from a
/// package because the one thing in this library that needs a hash is the
/// PKCE challenge of a sign-in, and a dependency-free package is worth more
/// to whoever is putting this in a program than not writing this out is
/// worth here.
Uint8List sha256(List<int> message) {
  final h = Uint32List.fromList([
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);

  // The message, a one bit, zeroes, and its length in bits as 64 big-endian
  // bits, out to a multiple of 64 bytes.
  final padded = (message.length + 9 + 63) ~/ 64 * 64;
  final block = Uint8List(padded)..setRange(0, message.length, message);
  block[message.length] = 0x80;
  final bits = message.length * 8;
  for (var i = 0; i < 8; i++) {
    block[padded - 1 - i] = (bits >> (8 * i)) & 0xff;
  }

  final w = Uint32List(64);
  final words = ByteData.sublistView(block);
  for (var start = 0; start < padded; start += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = words.getUint32(start + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _ror(w[i - 15], 7) ^ _ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _ror(w[i - 2], 17) ^ _ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _ror(e, 6) ^ _ror(e, 11) ^ _ror(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = hh + s1 + ch + _k[i] + w[i];
      final s0 = _ror(a, 2) ^ _ror(a, 13) ^ _ror(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = s0 + maj;
      hh = g;
      g = f;
      f = e;
      e = _word(d + t1);
      d = c;
      c = b;
      b = a;
      a = _word(t1 + t2);
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }

  final out = Uint8List(32);
  ByteData.sublistView(out);
  for (var i = 0; i < 8; i++) {
    ByteData.sublistView(out).setUint32(i * 4, h[i]);
  }
  return out;
}

/// The low 32 bits, which is what every step of the hash works in.
int _word(int value) => value & 0xffffffff;

/// A 32-bit rotation to the right.
int _ror(int value, int by) => _word((value >> by) | _word(value << (32 - by)));

/// The first 32 bits of the fractional parts of the cube roots of the first
/// 64 primes, as the standard has them.
const _k = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];
