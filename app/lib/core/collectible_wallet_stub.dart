import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

const _seedPrefKey = 'ss.devnet.wallet.seed';
const _b58Alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

final BigInt _q = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (BigInt.from(-121665) * BigInt.from(121666).modPow(_q - BigInt.two, _q)) % _q;
final BigInt _i = BigInt.two.modPow((_q - BigInt.one) >> 2, _q);
final (BigInt, BigInt, BigInt, BigInt) _basePoint = _computeBasePoint();
final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

final List<BigInt> _k512 = [
  '428a2f98d728ae22', '7137449123ef65cd', 'b5c0fbcfec4d3b2f', 'e9b5dba58189dbbc',
  '3956c25bf348b538', '59f111f1b605d019', '923f82a4af194f9b', 'ab1c5ed5da6d8118',
  'd807aa98a3030242', '12835b0145706fbe', '243185be4ee4b28c', '550c7dc3d5ffb4e2',
  '72be5d74f27b896f', '80deb1fe3b1696b1', '9bdc06a725c71235', 'c19bf174cf692694',
  'e49b69c19ef14ad2', 'efbe4786384f25e3', '0fc19dc68b8cd5b5', '240ca1cc77ac9c65',
  '2de92c6f592b0275', '4a7484aa6ea6e483', '5cb0a9dcbd41fbd4', '76f988da831153b5',
  '983e5152ee66dfab', 'a831c66d2db43210', 'b00327c898fb213f', 'bf597fc7beef0ee4',
  'c6e00bf33da88fc2', 'd5a79147930aa725', '06ca6351e003826f', '142929670a0e6e70',
  '27b70a8546d22ffc', '2e1b21385c26c926', '4d2c6dfc5ac42aed', '53380d139d95b3df',
  '650a73548baf63de', '766a0abb3c77b2a8', '81c2c92e47edaee6', '92722c851482353b',
  'a2bfe8a14cf10364', 'a81a664bbc423001', 'c24b8b70d0f89791', 'c76c51a30654be30',
  'd192e819d6ef5218', 'd69906245565a910', 'f40e35855771202a', '106aa07032bbd1b8',
  '19a4c116b8d2d0c8', '1e376c085141ab53', '2748774cdf8eeb99', '34b0bcb5e19b48a8',
  '391c0cb3c5c95a63', '4ed8aa4ae3418acb', '5b9cca4f7763e373', '682e6ff3d6b2b8a3',
  '748f82ee5defb2fc', '78a5636f43172f60', '84c87814a1f0ab72', '8cc702081a6439ec',
  '90befffa23631e28', 'a4506cebde82bde9', 'bef9a3f7b2c67915', 'c67178f2e372532b',
  'ca273eceea26619c', 'd186b8c721c0c207', 'eada7dd6cde0eb1e', 'f57d4f7fee6ed178',
  '06f067aa72176fba', '0a637dc5a2c898a6', '113f9804bef90dae', '1b710b35131c471b',
  '28db77f523047d84', '32caab7b40c72493', '3c9ebe0a15c9bebc', '431d67c49c100d4c',
  '4cc5d4becb3e42b6', '597f299cfc657e2a', '5fcb6fab3ad6faec', '6c44198c4a475817',
].map((s) => BigInt.parse(s, radix: 16)).toList(growable: false);

final List<BigInt> _h512 = [
  '6a09e667f3bcc908', 'bb67ae8584caa73b', '3c6ef372fe94f82b', 'a54ff53a5f1d36f1',
  '510e527fade682d1', '9b05688c2b3e6c1f', '1f83d9abfb41bd6b', '5be0cd19137e2179',
].map((s) => BigInt.parse(s, radix: 16)).toList(growable: false);

BigInt _rotr64(BigInt x, int n) => ((x >> n) | ((x << (64 - n)) & _mask64)) & _mask64;

Uint8List _sha512(List<int> data) {
  final msg = <int>[...data, 0x80];
  while (msg.length % 128 != 112) {
    msg.add(0);
  }
  var bitLen = BigInt.from(data.length) << 3;
  final lenBytes = Uint8List(16);
  for (var i = 15; i >= 0; i--) {
    lenBytes[i] = (bitLen & BigInt.from(0xff)).toInt();
    bitLen >>= 8;
  }
  msg.addAll(lenBytes);
  final h = List<BigInt>.of(_h512);
  final w = List<BigInt>.filled(80, BigInt.zero);
  for (var off = 0; off < msg.length; off += 128) {
    for (var i = 0; i < 16; i++) {
      var v = BigInt.zero;
      for (var b = 0; b < 8; b++) {
        v = (v << 8) | BigInt.from(msg[off + i * 8 + b]);
      }
      w[i] = v;
    }
    for (var i = 16; i < 80; i++) {
      final w15 = w[i - 15];
      final w2 = w[i - 2];
      final s0 = _rotr64(w15, 1) ^ _rotr64(w15, 8) ^ (w15 >> 7);
      final s1 = _rotr64(w2, 19) ^ _rotr64(w2, 61) ^ (w2 >> 6);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask64;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 80; i++) {
      final s1 = _rotr64(e, 14) ^ _rotr64(e, 18) ^ _rotr64(e, 41);
      final ch = (e & f) ^ ((~e & _mask64) & g);
      final t1 = (hh + s1 + ch + _k512[i] + w[i]) & _mask64;
      final s0 = _rotr64(a, 28) ^ _rotr64(a, 34) ^ _rotr64(a, 39);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask64;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask64;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask64;
    }
    h[0] = (h[0] + a) & _mask64;
    h[1] = (h[1] + b) & _mask64;
    h[2] = (h[2] + c) & _mask64;
    h[3] = (h[3] + d) & _mask64;
    h[4] = (h[4] + e) & _mask64;
    h[5] = (h[5] + f) & _mask64;
    h[6] = (h[6] + g) & _mask64;
    h[7] = (h[7] + hh) & _mask64;
  }
  final out = Uint8List(64);
  for (var i = 0; i < 8; i++) {
    var v = h[i];
    for (var b = 7; b >= 0; b--) {
      out[i * 8 + b] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
  }
  return out;
}

(BigInt, BigInt, BigInt, BigInt) _computeBasePoint() {
  final by = (BigInt.from(4) * BigInt.from(5).modPow(_q - BigInt.two, _q)) % _q;
  final xx = ((by * by - BigInt.one) * (_d * by * by + BigInt.one).modPow(_q - BigInt.two, _q)) % _q;
  var bx = xx.modPow((_q + BigInt.from(3)) >> 3, _q);
  if ((bx * bx - xx) % _q != BigInt.zero) {
    bx = (bx * _i) % _q;
  }
  if (bx.isOdd) {
    bx = _q - bx;
  }
  return (bx, by, BigInt.one, (bx * by) % _q);
}

(BigInt, BigInt, BigInt, BigInt) _edAdd((BigInt, BigInt, BigInt, BigInt) p1, (BigInt, BigInt, BigInt, BigInt) p2) {
  final (x1, y1, z1, t1) = p1;
  final (x2, y2, z2, t2) = p2;
  final a = ((y1 - x1) * (y2 - x2)) % _q;
  final b = ((y1 + x1) * (y2 + x2)) % _q;
  final c = (t1 * BigInt.two * _d * t2) % _q;
  final dd = (z1 * BigInt.two * z2) % _q;
  final e = (b - a) % _q;
  final f = (dd - c) % _q;
  final g = (dd + c) % _q;
  final h = (b + a) % _q;
  return ((e * f) % _q, (g * h) % _q, (f * g) % _q, (e * h) % _q);
}

(BigInt, BigInt, BigInt, BigInt) _edMul((BigInt, BigInt, BigInt, BigInt) p, BigInt scalar) {
  var r = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var cur = p;
  var k = scalar;
  while (k > BigInt.zero) {
    if (k.isOdd) {
      r = _edAdd(r, cur);
    }
    cur = _edAdd(cur, cur);
    k >>= 1;
  }
  return r;
}

Uint8List _encodePoint((BigInt, BigInt, BigInt, BigInt) p) {
  final (x, y, z, _) = p;
  final zi = z.modPow(_q - BigInt.two, _q);
  final xp = (x * zi) % _q;
  final yp = (y * zi) % _q;
  final out = _bigIntToLittleEndian(yp, 32);
  if (xp.isOdd) {
    out[31] |= 0x80;
  }
  return out;
}

BigInt _fromLittleEndian(List<int> bytes) {
  var res = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    res = (res << 8) | BigInt.from(bytes[i] & 0xff);
  }
  return res;
}

Uint8List _bigIntToLittleEndian(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  final mask = BigInt.from(0xff);
  for (var i = 0; i < length; i++) {
    out[i] = (v & mask).toInt();
    v >>= 8;
  }
  return out;
}

(BigInt, Uint8List, Uint8List) _expandSeed(Uint8List seed) {
  final h = _sha512(seed);
  final clamped = Uint8List.fromList(h.sublist(0, 32));
  clamped[0] &= 248;
  clamped[31] &= 127;
  clamped[31] |= 64;
  final a = _fromLittleEndian(clamped);
  final pub = _encodePoint(_edMul(_basePoint, a));
  return (a, h.sublist(32, 64), pub);
}

Uint8List _ed25519Sign(List<int> message, Uint8List seed) {
  final (a, prefix, pub) = _expandSeed(seed);
  final rHash = _sha512([...prefix, ...message]);
  final r = _fromLittleEndian(rHash) % _l;
  final bigR = _encodePoint(_edMul(_basePoint, r));
  final kHash = _sha512([...bigR, ...pub, ...message]);
  final k = _fromLittleEndian(kHash) % _l;
  final s = (r + k * a) % _l;
  final sBytes = _bigIntToLittleEndian(s, 32);
  return Uint8List.fromList([...bigR, ...sBytes]);
}

String _base58Encode(Uint8List bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  final chars = <String>[];
  final base = BigInt.from(58);
  while (value > BigInt.zero) {
    final rem = (value % base).toInt();
    value = value ~/ base;
    chars.add(_b58Alphabet[rem]);
  }
  for (final b in bytes) {
    if (b == 0) {
      chars.add(_b58Alphabet[0]);
    } else {
      break;
    }
  }
  return chars.reversed.join();
}

Future<Uint8List> _loadOrCreateSeed() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(_seedPrefKey);
  if (existing != null) {
    final decoded = base64Decode(existing);
    if (decoded.length == 32) return decoded;
  }
  final rng = Random.secure();
  final seed = Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  await prefs.setString(_seedPrefKey, base64Encode(seed));
  return seed;
}

(int, int) _readCompactU16(Uint8List bytes, int offset) {
  var val = 0;
  var shift = 0;
  var pos = offset;
  while (true) {
    final b = bytes[pos++];
    val |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) break;
    shift += 7;
  }
  return (val, pos);
}

Future<String> connectCollectibleWallet() async {
  final seed = await _loadOrCreateSeed();
  final (_, _, pub) = _expandSeed(seed);
  return _base58Encode(pub);
}

Future<String> signCollectibleMessage(String message) async {
  final seed = await _loadOrCreateSeed();
  final sig = _ed25519Sign(utf8.encode(message), seed);
  return base64Encode(sig);
}

Future<String> signCollectibleTransaction(String transaction) async {
  final seed = await _loadOrCreateSeed();
  final (_, _, pub) = _expandSeed(seed);
  final txBytes = Uint8List.fromList(base64Decode(transaction));
  final (numSigs, sigsStart) = _readCompactU16(txBytes, 0);
  final msgStart = sigsStart + numSigs * 64;
  final messageBytes = txBytes.sublist(msgStart);
  final numRequired = messageBytes[0];
  final (_, accountsStart) = _readCompactU16(messageBytes, 3);
  var signerIndex = -1;
  for (var i = 0; i < numRequired; i++) {
    final keyStart = accountsStart + i * 32;
    var match = true;
    for (var j = 0; j < 32; j++) {
      if (messageBytes[keyStart + j] != pub[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      signerIndex = i;
      break;
    }
  }
  if (signerIndex < 0) {
    throw StateError('Active devnet wallet is not a required signer on this transaction.');
  }
  final sig = _ed25519Sign(messageBytes, seed);
  final dest = sigsStart + signerIndex * 64;
  for (var i = 0; i < 64; i++) {
    txBytes[dest + i] = sig[i];
  }
  return base64Encode(txBytes);
}
