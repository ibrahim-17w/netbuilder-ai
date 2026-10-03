/// The Packet Tracer save container, implemented in Dart.
///
/// This is a port of `sidecar/pkt_codec.py`. That module is pure Python with
/// no third-party imports, which is what makes an on-device writer possible:
/// the .pkt container is Twofish-128-EAX over a zlib stream of the save XML,
/// wrapped in two byte-level obfuscation stages. Nothing here needs Packet
/// Tracer, a Python runtime, a server or a desktop - which is the whole
/// reason it exists. On Android there is no sidecar to call, so the format has
/// to be understood by the app itself.
///
/// The cipher is fixed by the format: a 128-bit key of 0x89 bytes and a
/// nonce of 0x10 bytes. Only Twofish-128 is implemented, because the
/// container never uses another key size and the other key schedules would be
/// untested code.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _block = 16;

/// The fixed container key Packet Tracer uses.
final Uint8List ptKey = Uint8List(_block)..fillRange(0, _block, 0x89);

/// The fixed container nonce Packet Tracer uses.
final Uint8List ptNonce = Uint8List(_block)..fillRange(0, _block, 0x10);

/// A save's XML is normally well under 10 MB. The cap exists so a corrupt or
/// hostile size prefix cannot make the app allocate forever.
const int maxXmlBytes = 64 * 1024 * 1024;

const int _minPktBytes = _block * 2 + 5;

/// The buffer is not a Packet Tracer save this codec can read.
class PktFormatError implements Exception {
  final String message;
  const PktFormatError(this.message);
  @override
  String toString() => message;
}

int _mask(int v) => v & 0xFFFFFFFF;

int _byte(int word, int n) => (word >> (8 * n)) & 0xFF;

int _rotr32(int value, int n) =>
    _mask((value >> n) | _mask(value) << (32 - n));

int _rotl32(int value, int n) =>
    _mask(_mask(value) << n | _mask(value) >> (32 - n));

// --- Twofish ---------------------------------------------------------------

const List<List<int>> _qt0 = [
  [8, 1, 7, 13, 6, 15, 3, 2, 0, 11, 5, 9, 14, 12, 10, 4],
  [2, 8, 11, 13, 15, 7, 6, 14, 3, 1, 9, 4, 0, 10, 12, 5],
];
const List<List<int>> _qt1 = [
  [14, 12, 11, 8, 1, 2, 3, 5, 15, 4, 10, 6, 7, 0, 9, 13],
  [1, 14, 2, 11, 4, 12, 3, 7, 6, 13, 10, 5, 15, 9, 0, 8],
];
const List<List<int>> _qt2 = [
  [11, 10, 5, 14, 6, 13, 9, 0, 12, 8, 15, 3, 2, 4, 7, 1],
  [4, 12, 7, 5, 1, 6, 9, 10, 0, 14, 13, 8, 2, 11, 3, 15],
];
const List<List<int>> _qt3 = [
  [13, 7, 15, 4, 1, 2, 6, 14, 9, 11, 3, 0, 8, 5, 12, 10],
  [11, 9, 5, 1, 12, 3, 13, 14, 6, 4, 7, 15, 2, 0, 8, 10],
];

const List<int> _tab5b = [0, 90, 180, 238];
const List<int> _tabEf = [0, 238, 180, 90];
const List<int> _ror4 = [0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15];
const List<int> _ashx = [0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 5, 14, 7];

/// Expanded Twofish key: round subkeys plus key-dependent S-box tables.
///
/// Key expansion is deterministic and the container key never changes, so
/// this is built once per isolate and shared afterwards - the tables cost
/// 4x256 ints to build and nothing else depends on them changing.
class TwofishKey {
  late final Uint32List lKey;
  late final List<Uint32List> mkTab;

  static final Map<String, TwofishKey> _cache = {};

  factory TwofishKey(Uint8List key) {
    if (key.length != _block) {
      throw PktFormatError(
        'this codec only implements Twofish-128 '
        '(got a ${key.length * 8}-bit key)',
      );
    }
    final cacheKey = base64Encode(key);
    final hit = _cache[cacheKey];
    if (hit != null) return hit;
    final built = TwofishKey._(key);
    _cache[cacheKey] = built;
    return built;
  }

  TwofishKey._(Uint8List key) {
    final qTab = _buildQTables();
    final mTab = _buildMTables(qTab);
    final words = <int>[
      _le32(key, 0),
      _le32(key, 4),
      _le32(key, 8),
      _le32(key, 12),
    ];
    final meKey = [words[0], words[2], 0, 0];
    final moKey = [words[1], words[3], 0, 0];
    final sKey = [0, _mdsRem(words[0], words[1])];
    sKey[0] = _mdsRem(words[2], words[3]);
    lKey = _keySchedule(qTab, mTab, meKey, moKey);
    mkTab = _sboxTables(qTab, mTab, sKey, meKey, moKey);
  }

  static int _le32(Uint8List b, int at) =>
      b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

  static List<Uint32List> _buildQTables() {
    final t0 = Uint32List(256);
    final t1 = Uint32List(256);
    for (var value = 0; value < 256; value++) {
      for (var n = 0; n < 2; n++) {
        final a0 = value >> 4;
        final b0 = value & 15;
        final a1 = a0 ^ b0;
        final b1 = _ror4[b0] ^ _ashx[a0];
        final a2 = _qt0[n][a1];
        final b2 = _qt1[n][b1];
        final a3 = a2 ^ b2;
        final b3 = _ror4[b2] ^ _ashx[a2];
        final v = (_qt3[n][b3] << 4) | _qt2[n][a3];
        if (n == 0) {
          t0[value] = v;
        } else {
          t1[value] = v;
        }
      }
    }
    return [t0, t1];
  }

  static List<Uint32List> _buildMTables(List<Uint32List> qTab) {
    final m = List<Uint32List>.generate(
      4,
      (_) => Uint32List(256),
      growable: false,
    );
    for (var value = 0; value < 256; value++) {
      var f01 = qTab[1][value];
      var f5b = f01 ^ (f01 >> 2) ^ _tab5b[f01 & 3];
      var fef = f01 ^ (f01 >> 1) ^ (f01 >> 2) ^ _tabEf[f01 & 3];
      m[0][value] = _mask(f01 + (f5b << 8) + (fef << 16) + (fef << 24));
      m[2][value] = _mask(f5b + (fef << 8) + (f01 << 16) + (fef << 24));
      f01 = qTab[0][value];
      f5b = f01 ^ (f01 >> 2) ^ _tab5b[f01 & 3];
      fef = f01 ^ (f01 >> 1) ^ (f01 >> 2) ^ _tabEf[f01 & 3];
      m[1][value] = _mask(fef + (fef << 8) + (f5b << 16) + (f01 << 24));
      m[3][value] = _mask(f5b + (f01 << 8) + (fef << 16) + (f5b << 24));
    }
    return m;
  }

  /// RS-matrix multiply used for the key-dependent S-box material.
  static int _mdsRem(int p0In, int p1In) {
    var p0 = p0In;
    var p1 = p1In;
    for (var i = 0; i < 8; i++) {
      final top = p1 >> 24;
      p1 = ((p1 << 8) & 0xFFFFFFFF) | (p0 >> 24);
      p0 = (p0 << 8) & 0xFFFFFFFF;
      var u = (top << 1) & 0xFFFFFFFF;
      if (top & 0x80 != 0) u ^= 0x0000014D;
      p1 ^= top ^ ((u << 16) & 0xFFFFFFFF);
      u ^= top >> 1;
      if (top & 0x01 != 0) u ^= 0x0000014D >> 1;
      p1 ^= ((u << 24) & 0xFFFFFFFF) | ((u << 8) & 0xFFFFFFFF);
    }
    return p1 & 0xFFFFFFFF;
  }

  static int _h(
    List<Uint32List> qTab,
    List<Uint32List> mTab,
    int x,
    List<int> key,
  ) {
    var b0 = _byte(x, 0);
    var b1 = _byte(x, 1);
    var b2 = _byte(x, 2);
    var b3 = _byte(x, 3);
    b0 = qTab[0][qTab[0][b0] ^ _byte(key[1], 0)] ^ _byte(key[0], 0);
    b1 = qTab[0][qTab[1][b1] ^ _byte(key[1], 1)] ^ _byte(key[0], 1);
    b2 = qTab[1][qTab[0][b2] ^ _byte(key[1], 2)] ^ _byte(key[0], 2);
    b3 = qTab[1][qTab[1][b3] ^ _byte(key[1], 3)] ^ _byte(key[0], 3);
    return mTab[0][b0] ^ mTab[1][b1] ^ mTab[2][b2] ^ mTab[3][b3];
  }

  static Uint32List _keySchedule(
    List<Uint32List> qTab,
    List<Uint32List> mTab,
    List<int> meKey,
    List<int> moKey,
  ) {
    final out = Uint32List(40);
    for (var i = 0; i < 40; i += 2) {
      var a = _mask(0x01010101 * i);
      var b = _mask(a + 0x01010101);
      a = _h(qTab, mTab, a, meKey);
      b = _rotl32(_h(qTab, mTab, b, moKey), 8);
      out[i] = _mask(a + b);
      out[i + 1] = _rotl32(_mask(a + 2 * b), 9);
    }
    return out;
  }

  static List<Uint32List> _sboxTables(
    List<Uint32List> qTab,
    List<Uint32List> mTab,
    List<int> sKey,
    List<int> meKey,
    List<int> moKey,
  ) {
    final mk = List<Uint32List>.generate(
      4,
      (_) => Uint32List(256),
      growable: false,
    );
    for (var value = 0; value < 256; value++) {
      mk[0][value] =
          mTab[0][qTab[0][qTab[0][value] ^ _byte(sKey[1], 0)] ^ _byte(sKey[0], 0)];
      mk[1][value] =
          mTab[1][qTab[0][qTab[1][value] ^ _byte(sKey[1], 1)] ^ _byte(sKey[0], 1)];
      mk[2][value] =
          mTab[2][qTab[1][qTab[0][value] ^ _byte(sKey[1], 2)] ^ _byte(sKey[0], 2)];
      mk[3][value] =
          mTab[3][qTab[1][qTab[1][value] ^ _byte(sKey[1], 3)] ^ _byte(sKey[0], 3)];
    }
    return mk;
  }

  Uint8List encryptBlock(Uint8List block) {
    var x0 = _le32(block, 0) ^ lKey[0];
    var x1 = _le32(block, 4) ^ lKey[1];
    var x2 = _le32(block, 8) ^ lKey[2];
    var x3 = _le32(block, 12) ^ lKey[3];
    final mk = mkTab;
    final lk = lKey;
    for (var i = 0; i < 8; i++) {
      final t1 =
          mk[0][_byte(x1, 3)] ^
          mk[1][_byte(x1, 0)] ^
          mk[2][_byte(x1, 1)] ^
          mk[3][_byte(x1, 2)];
      final t0 =
          mk[0][_byte(x0, 0)] ^
          mk[1][_byte(x0, 1)] ^
          mk[2][_byte(x0, 2)] ^
          mk[3][_byte(x0, 3)];
      x2 = _rotr32(_mask(x2 ^ _mask(t0 + t1 + lk[4 * i + 8])), 1);
      x3 = _mask(_rotl32(x3, 1) ^ _mask(t0 + 2 * t1 + lk[4 * i + 9]));
      final t1b =
          mk[0][_byte(x3, 3)] ^
          mk[1][_byte(x3, 0)] ^
          mk[2][_byte(x3, 1)] ^
          mk[3][_byte(x3, 2)];
      final t0b =
          mk[0][_byte(x2, 0)] ^
          mk[1][_byte(x2, 1)] ^
          mk[2][_byte(x2, 2)] ^
          mk[3][_byte(x2, 3)];
      x0 = _rotr32(_mask(x0 ^ _mask(t0b + t1b + lk[4 * i + 10])), 1);
      x1 = _mask(_rotl32(x1, 1) ^ _mask(t0b + 2 * t1b + lk[4 * i + 11]));
    }
    return _pack32(_mask(x2 ^ lk[4]), _mask(x3 ^ lk[5]), _mask(x0 ^ lk[6]),
        _mask(x1 ^ lk[7]));
  }

  Uint8List decryptBlock(Uint8List block) {
    var x0 = _le32(block, 0) ^ lKey[4];
    var x1 = _le32(block, 4) ^ lKey[5];
    var x2 = _le32(block, 8) ^ lKey[6];
    var x3 = _le32(block, 12) ^ lKey[7];
    final mk = mkTab;
    final lk = lKey;
    for (var i = 7; i >= 0; i--) {
      final t1 =
          mk[0][_byte(x1, 3)] ^
          mk[1][_byte(x1, 0)] ^
          mk[2][_byte(x1, 1)] ^
          mk[3][_byte(x1, 2)];
      final t0 =
          mk[0][_byte(x0, 0)] ^
          mk[1][_byte(x0, 1)] ^
          mk[2][_byte(x0, 2)] ^
          mk[3][_byte(x0, 3)];
      x2 = _mask(_rotl32(x2, 1) ^ _mask(t0 + t1 + lk[4 * i + 10]));
      x3 = _rotr32(_mask(x3 ^ _mask(t0 + 2 * t1 + lk[4 * i + 11])), 1);
      final t1b =
          mk[0][_byte(x3, 3)] ^
          mk[1][_byte(x3, 0)] ^
          mk[2][_byte(x3, 1)] ^
          mk[3][_byte(x3, 2)];
      final t0b =
          mk[0][_byte(x2, 0)] ^
          mk[1][_byte(x2, 1)] ^
          mk[2][_byte(x2, 2)] ^
          mk[3][_byte(x2, 3)];
      x0 = _mask(_rotl32(x0, 1) ^ _mask(t0b + t1b + lk[4 * i + 8]));
      x1 = _rotr32(_mask(x1 ^ _mask(t0b + 2 * t1b + lk[4 * i + 9])), 1);
    }
    return _pack32(_mask(x2 ^ lk[0]), _mask(x3 ^ lk[1]), _mask(x0 ^ lk[2]),
        _mask(x1 ^ lk[3]));
  }

  static Uint8List _pack32(int a, int b, int c, int d) {
    final out = Uint8List(_block);
    final bd = ByteData.view(out.buffer);
    bd.setUint32(0, a, Endian.little);
    bd.setUint32(4, b, Endian.little);
    bd.setUint32(8, c, Endian.little);
    bd.setUint32(12, d, Endian.little);
    return out;
  }
}

// --- CMAC / CTR / EAX ------------------------------------------------------

Uint8List _xor(Uint8List a, Uint8List b) {
  final out = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = a[i] ^ b[i];
  }
  return out;
}

Uint8List _leftShiftOne(Uint8List bits) {
  final out = Uint8List(bits.length);
  var carry = 0;
  for (var i = bits.length - 1; i >= 0; i--) {
    out[i] = ((bits[i] << 1) & 0xFF) | carry;
    carry = (bits[i] & 0x80) >> 7;
  }
  return out;
}

/// CMAC over any 16-byte block cipher (RFC 4493 subkeys).
class Cmac {
  final Uint8List Function(Uint8List) encrypt;
  late final Uint8List k1;
  late final Uint8List k2;

  Cmac(this.encrypt) {
    final lValue = encrypt(Uint8List(_block));
    k1 = _leftShiftOne(lValue);
    if (lValue[0] & 0x80 != 0) {
      final r = Uint8List(_block)..fillRange(0, _block - 1, 0);
      r[_block - 1] = 0x87;
      for (var i = 0; i < _block; i++) {
        k1[i] ^= r[i];
      }
    }
    k2 = _leftShiftOne(k1);
    if (k1[0] & 0x80 != 0) {
      final r = Uint8List(_block)..fillRange(0, _block - 1, 0);
      r[_block - 1] = 0x87;
      for (var i = 0; i < _block; i++) {
        k2[i] ^= r[i];
      }
    }
  }

  Uint8List digest(Uint8List data) {
    final blocks = <Uint8List>[];
    if (data.isEmpty) {
      blocks.add(Uint8List(0));
    } else {
      for (var i = 0; i < data.length; i += _block) {
        final end = i + _block > data.length ? data.length : i + _block;
        blocks.add(Uint8List.sublistView(data, i, end));
      }
    }
    final tail = blocks.removeLast();
    Uint8List last;
    if (tail.length == _block) {
      last = _xor(tail, k1);
    } else {
      final padded = Uint8List(_block);
      padded.setRange(0, tail.length, tail);
      padded[tail.length] = 0x80;
      last = _xor(padded, k2);
    }
    var state = Uint8List(_block);
    for (final block in blocks) {
      state = encrypt(_xor(state, block));
    }
    return encrypt(_xor(state, last));
  }
}

/// EAX authenticated encryption (Bellare-Rogaway-Wagner).
class Eax {
  final Uint8List Function(Uint8List) encrypt;
  final Cmac _cmac;

  Eax(this.encrypt) : _cmac = Cmac(encrypt);

  Uint8List _omac(int prefix, Uint8List data) {
    final buf = Uint8List(_block + data.length);
    buf[_block - 1] = prefix;
    buf.setRange(_block, _block + data.length, data);
    return _cmac.digest(buf);
  }

  Uint8List _ctr(Uint8List nonceTag, Uint8List data) {
    final counter = Uint8List.fromList(nonceTag);
    final out = Uint8List(data.length);
    var offset = 0;
    while (offset < data.length) {
      final keystream = encrypt(Uint8List.fromList(counter));
      // Big-endian increment, applied AFTER this block's keystream.
      for (var i = _block - 1; i >= 0; i--) {
        counter[i] = (counter[i] + 1) & 0xFF;
        if (counter[i] != 0) break;
      }
      final end = offset + _block > data.length ? data.length : offset + _block;
      for (var i = offset; i < end; i++) {
        out[i] = data[i] ^ keystream[i - offset];
      }
      offset += _block;
    }
    return out;
  }

  ({Uint8List ciphertext, Uint8List tag}) encryptPkt(
    Uint8List nonce,
    Uint8List plaintext,
  ) {
    final nonceTag = _omac(0x00, nonce);
    final headerTag = _omac(0x01, Uint8List(0));
    final ciphertext = _ctr(nonceTag, plaintext);
    final cipherTag = _omac(0x02, ciphertext);
    return (
      ciphertext: ciphertext,
      tag: _xor(_xor(nonceTag, headerTag), cipherTag),
    );
  }

  Uint8List decryptPkt(
    Uint8List nonce,
    Uint8List ciphertext,
    Uint8List tag,
  ) {
    final nonceTag = _omac(0x00, nonce);
    final plaintext = _ctr(nonceTag, ciphertext);
    final headerTag = _omac(0x01, Uint8List(0));
    final cipherTag = _omac(0x02, ciphertext);
    final expected = _xor(_xor(nonceTag, headerTag), cipherTag);
    if (!_sameBytes(expected, tag)) {
      throw const PktFormatError(
        'EAX authentication failed (wrong key, corrupted file, '
        'or a newer format)',
      );
    }
    return plaintext;
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Legacy Twofish-CBC decryption (Packet Tracer <= 7.2.1 saves).
Uint8List cbcDecrypt(TwofishKey key, Uint8List data, Uint8List iv) {
  if (data.length % _block != 0) {
    throw const PktFormatError('legacy CBC payload is not block-aligned');
  }
  final out = Uint8List(data.length);
  var previous = Uint8List.fromList(iv);
  for (var offset = 0; offset < data.length; offset += _block) {
    final block = Uint8List.sublistView(data, offset, offset + _block);
    final plain = key.decryptBlock(Uint8List.fromList(block));
    for (var i = 0; i < _block; i++) {
      out[offset + i] = plain[i] ^ previous[i];
    }
    previous = Uint8List.fromList(block);
  }
  return out;
}

// --- Obfuscation stages ----------------------------------------------------

Uint8List _stageOuterDecode(Uint8List data) {
  final length = data.length;
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = data[length - 1 - i] ^ ((length - i * length) & 0xFF);
  }
  return out;
}

Uint8List _stageOuterEncode(Uint8List blob) {
  final length = blob.length;
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[length - 1 - i] = blob[i] ^ ((length - i * length) & 0xFF);
  }
  return out;
}

/// XOR each byte with `(length - i) & 0xFF`; its own inverse.
Uint8List _stageInner(Uint8List data) {
  final length = data.length;
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = data[i] ^ ((length - i) & 0xFF);
  }
  return out;
}

Uint8List _qtCompress(Uint8List xml) {
  final compressed = Uint8List.fromList(ZLibEncoder().convert(xml));
  final out = Uint8List(4 + compressed.length);
  ByteData.view(out.buffer).setUint32(0, xml.length, Endian.big);
  out.setRange(4, out.length, compressed);
  return out;
}

Uint8List _qtUncompress(Uint8List blob) {
  if (blob.length < 6) {
    throw const PktFormatError('compressed payload is too short');
  }
  final declared =
      ByteData.view(blob.buffer, blob.offsetInBytes).getUint32(0, Endian.big);
  if (declared > maxXmlBytes) {
    throw PktFormatError(
      'declared size $declared exceeds the $maxXmlBytes byte cap',
    );
  }
  final body = Uint8List.sublistView(blob, 4);
  final data = Uint8List.fromList(ZLibDecoder().convert(body));
  if (data.isEmpty || data[0] != 0x3C /* < */) {
    throw const PktFormatError('payload does not decompress to XML');
  }
  return data.length > declared ? Uint8List.sublistView(data, 0, declared) : data;
}

/// Replace XML-illegal control characters so a document stays parseable.
///
/// Characters XML 1.0 does not allow anywhere, not even escaped. Packet
/// Tracer writes some of them in banner delimiters and several of its own
/// sample saves carry them in a device's startup config, so they have to be
/// dealt with on the way in AND on the way out: one in a harvested template
/// block makes that block unparseable, and one in a generated config line
/// makes the whole .pkt unopenable.
Uint8List xmlSafe(Uint8List data) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    final b = data[i];
    out[i] = (b <= 0x08 || b == 0x0B || b == 0x0C || (b >= 0x0E && b <= 0x1F))
        ? 0x20
        : b;
  }
  return out;
}

/// True when the buffer looks like a Packet Tracer save container.
bool isPkt(List<int> data) {
  if (data.length < _minPktBytes) return false;
  for (final b in data) {
    if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B ||
        b == 0x0C) {
      continue;
    }
    return b != 0x3C /* < */;
  }
  return true;
}

/// Decode a .pkt/.pka container and return the XML bytes.
///
/// Throws [PktFormatError] when the buffer is not a save file this codec can
/// read.
Uint8List decryptPkt(List<int> raw) {
  final data = Uint8List.fromList(raw);
  if (data.length < _minPktBytes) {
    throw PktFormatError('file is too small (${data.length} bytes)');
  }
  final first = isPkt(data) ? data.first : 0x3C;
  if (first == 0x3C) {
    throw const PktFormatError(
      'this file is plain XML, not an encrypted save',
    );
  }
  final stage1 = _stageOuterDecode(data);
  final key = TwofishKey(ptKey);
  final body = Uint8List.sublistView(stage1, 0, stage1.length - _block);
  final tag = Uint8List.sublistView(stage1, stage1.length - _block);
  final errors = <String>[];
  try {
    final decrypted = Eax(key.encryptBlock).decryptPkt(ptNonce, body, tag);
    return _qtUncompress(_stageInner(decrypted));
  } on PktFormatError catch (e) {
    errors.add('EAX: $e');
  }
  // Packet Tracer 7.2.1 and older used CBC for the same container.
  try {
    final decrypted = cbcDecrypt(key, Uint8List.fromList(body), ptNonce);
    return _qtUncompress(_stageInner(decrypted));
  } catch (e) {
    errors.add('CBC: $e');
  }
  throw PktFormatError('could not decode the file (${errors.join('; ')})');
}

/// Encode XML bytes into a .pkt container.
Uint8List encryptPkt(String xml) {
  if (xml.isEmpty) {
    throw const PktFormatError('refusing to encode an empty document');
  }
  final bytes = Uint8List.fromList(utf8.encode(xml));
  final key = TwofishKey(ptKey);
  final compressed = _stageInner(_qtCompress(bytes));
  final result = Eax(key.encryptBlock).encryptPkt(ptNonce, compressed);
  final joined = Uint8List(result.ciphertext.length + result.tag.length)
    ..setRange(0, result.ciphertext.length, result.ciphertext)
    ..setRange(result.ciphertext.length, result.ciphertext.length + result.tag.length,
        result.tag);
  return _stageOuterEncode(joined);
}