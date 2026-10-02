import 'dart:typed_data';

/// Minimal pure-Dart SHA-256 for synchronous storage-key derivation.
///
/// Used exclusively by [ContainerRepository] to produce collision-free
/// Keystore keys from long URIs. Kept here (instead of `package:crypto`)
/// because the app routes all security-critical hashing through the native
/// layer (`VaultCryptoApi` / `VaultHashApi`), and this is the only Dart-side
/// call site that needs a synchronous, non-async SHA-256.
String sha256Hex(List<int> input) {
  final msg = Uint8List.fromList(input);
  final padded = _pad(msg);
  final h = Uint32List.fromList(_h0);

  for (var offset = 0; offset < padded.length; offset += 64) {
    _compress(h, Uint8List.sublistView(padded, offset, offset + 64));
  }

  final out = StringBuffer();
  for (var i = 0; i < 8; i++) {
    out.write(h[i].toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}

// ---------- internals ----------

const _h0 = <int>[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

Uint8List _pad(Uint8List msg) {
  final bitLen = msg.length * 8;
  // 1 byte for 0x80, then zeros until 56 mod 64, then 8 bytes length
  var padLen = 64 - ((msg.length + 9) % 64);
  if (padLen == 64) padLen = 0;
  final total = msg.length + 1 + padLen + 8;
  final out = Uint8List(total);
  out.setRange(0, msg.length, msg);
  out[msg.length] = 0x80;
  // big-endian 64-bit bit-length in the last 8 bytes
  out[total - 4] = (bitLen >> 24) & 0xFF;
  out[total - 3] = (bitLen >> 16) & 0xFF;
  out[total - 2] = (bitLen >> 8) & 0xFF;
  out[total - 1] = bitLen & 0xFF;
  return out;
}

void _compress(Uint32List hash, Uint8List block) {
  final w = Uint32List(64);
  for (var i = 0; i < 16; i++) {
    w[i] = (block[i * 4] << 24) |
        (block[i * 4 + 1] << 16) |
        (block[i * 4 + 2] << 8) |
        block[i * 4 + 3];
  }
  for (var i = 16; i < 64; i++) {
    final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
    final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
  }

  var a = hash[0], b = hash[1], c = hash[2], d = hash[3];
  var e = hash[4], f = hash[5], g = hash[6], h = hash[7];

  for (var i = 0; i < 64; i++) {
    final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final ch = (e & f) ^ ((~e) & g);
    final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
    final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = (s0 + maj) & 0xFFFFFFFF;

    h = g;
    g = f;
    f = e;
    e = (d + t1) & 0xFFFFFFFF;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xFFFFFFFF;
  }

  hash[0] = (hash[0] + a) & 0xFFFFFFFF;
  hash[1] = (hash[1] + b) & 0xFFFFFFFF;
  hash[2] = (hash[2] + c) & 0xFFFFFFFF;
  hash[3] = (hash[3] + d) & 0xFFFFFFFF;
  hash[4] = (hash[4] + e) & 0xFFFFFFFF;
  hash[5] = (hash[5] + f) & 0xFFFFFFFF;
  hash[6] = (hash[6] + g) & 0xFFFFFFFF;
  hash[7] = (hash[7] + h) & 0xFFFFFFFF;
}
