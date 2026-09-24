"""Offline Packet Tracer save codec: decode and encode .pkt/.pka containers.

A saved Packet Tracer topology is one XML document wrapped in three layers.
Decoding a file is, in order:

1. **Reverse-XOR obfuscation** (the "outer" scramble)::

       blob[i] = file[length - 1 - i] ^ ((length - i * length) & 0xFF)

2. **Authenticated decryption**: Twofish-128 in EAX mode.  The key is 16
   bytes of 0x89 and the nonce is 16 bytes of 0x10 for .pkt/.pka files; the
   last 16 bytes of the buffer are the EAX tag and everything before it is
   the ciphertext.  (Packet Tracer <= 7.2.1 used Twofish-CBC with the same
   key/nonce instead; ``decrypt_pkt`` falls back to it so older saves load.)

3. **Rolling XOR obfuscation** (the "inner" scramble)::

       x[i] ^= (length - i) & 0xFF

4. **Qt compression**: a 4-byte big-endian uncompressed size followed by a
   zlib stream.

Encoding is the exact reverse.  Nothing here touches Packet Tracer, the
network, or the filesystem: bytes in, bytes out.  The whole stack is pure
stdlib and 128-bit-keyed Twofish, which is what the container uses.

Provenance: the layering was established by public reverse engineering
(axcheron/ptexplorer for the pre-5 format, ferib.dev for 7.2.1,
mircodz/pka2xml and strykey/pka-decipher for the 7.3+ Twofish-EAX format).
This module reimplements it from scratch and was verified on 2026-09-19
against a Packet Tracer 9.0.0.0810 save: the EAX tag validates, the file
decompresses to its 994,119-byte XML, and re-encoding the XML (including
edited XML) decodes back byte-identically.

The Twofish primitive is checked against the published zero-key test vector
in :func:`twofish_selftest`; :func:`codec_selftest` adds the container
round trip.
"""

from __future__ import annotations

import re
import struct
import time
import zlib

__all__ = [
    "PktFormatError",
    "PT_KEY",
    "PT_NONCE",
    "MAX_XML_BYTES",
    "decrypt_pkt",
    "encrypt_pkt",
    "is_pkt",
    "pkt_xml_summary",
    "codec_selftest",
    "twofish_selftest",
]

BLOCK = 16
PT_KEY = bytes([0x89]) * BLOCK
PT_NONCE = bytes([0x10]) * BLOCK

# A save's XML is typically well under 10 MB.  The cap only exists so a
# corrupt or hostile size prefix cannot make the process allocate forever.
MAX_XML_BYTES = 64 * 1024 * 1024
MIN_PKT_BYTES = BLOCK * 2 + 5


class PktFormatError(ValueError):
    """The buffer is not a Packet Tracer save this codec can read."""


# ---------------------------------------------------------------------------
# Twofish (128-bit key, 128-bit block)
#
# Table-based implementation of the algorithm Packet Tracer uses.  Key sizes
# other than 128 bits are rejected: the container never uses them and the
# key-schedule branches would be untested code.
# ---------------------------------------------------------------------------

_Q_TABLES = (
    # qt0
    ([8, 1, 7, 13, 6, 15, 3, 2, 0, 11, 5, 9, 14, 12, 10, 4],
     [2, 8, 11, 13, 15, 7, 6, 14, 3, 1, 9, 4, 0, 10, 12, 5]),
    # qt1
    ([14, 12, 11, 8, 1, 2, 3, 5, 15, 4, 10, 6, 7, 0, 9, 13],
     [1, 14, 2, 11, 4, 12, 3, 7, 6, 13, 10, 5, 15, 9, 0, 8]),
    # qt2
    ([11, 10, 5, 14, 6, 13, 9, 0, 12, 8, 15, 3, 2, 4, 7, 1],
     [4, 12, 7, 5, 1, 6, 9, 10, 0, 14, 13, 8, 2, 11, 3, 15]),
    # qt3
    ([13, 7, 15, 4, 1, 2, 6, 14, 9, 11, 3, 0, 8, 5, 12, 10],
     [11, 9, 5, 1, 12, 3, 13, 14, 6, 4, 7, 15, 2, 0, 8, 10]),
)
_TAB_5B = (0, 90, 180, 238)
_TAB_EF = (0, 238, 180, 90)
_ROR4 = (0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15)
_ASHX = (0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 5, 14, 7)


def _byte(word: int, n: int) -> int:
    return (word >> (8 * n)) & 0xFF


def _rotr32(value: int, n: int) -> int:
    return ((value >> n) | (value << (32 - n))) & 0xFFFFFFFF


def _rotl32(value: int, n: int) -> int:
    return ((value << n) | (value >> (32 - n))) & 0xFFFFFFFF


class _TwofishKey:
    """Expanded Twofish key: round subkeys + key-dependent S-box tables."""

    __slots__ = ("l_key", "mk_tab")

    def __init__(self, key: bytes):
        if len(key) != BLOCK:
            raise PktFormatError(
                "this codec only implements Twofish-128 "
                f"(got a {len(key) * 8}-bit key)")
        q_tab = self._q_tables()
        m_tab = self._m_tables(q_tab)
        words = [struct.unpack("<L", key[i:i + 4])[0] for i in range(0, 16, 4)]
        me_key = [words[0], words[2], 0, 0]
        mo_key = [words[1], words[3], 0, 0]
        # S-box key material: the RS matrix encoding of each key pair.
        s_key = [0, 0]
        s_key[1] = self._mds_rem(words[0], words[1])
        s_key[0] = self._mds_rem(words[2], words[3])
        self.l_key = self._key_schedule(q_tab, m_tab, me_key, mo_key)
        self.mk_tab = self._sbox_tables(q_tab, m_tab, s_key, me_key, mo_key)

    # -- static tables -----------------------------------------------------

    @staticmethod
    def _q_tables() -> list[list[int]]:
        tables = [[0] * 256, [0] * 256]
        for value in range(256):
            for n in (0, 1):
                a0 = value >> 4
                b0 = value & 15
                a1 = a0 ^ b0
                b1 = _ROR4[b0] ^ _ASHX[a0]
                a2 = _Q_TABLES[0][n][a1]
                b2 = _Q_TABLES[1][n][b1]
                a3 = a2 ^ b2
                b3 = _ROR4[b2] ^ _ASHX[a2]
                tables[n][value] = ((_Q_TABLES[3][n][b3] << 4)
                                    | _Q_TABLES[2][n][a3])
        return tables

    @staticmethod
    def _m_tables(q_tab) -> list[list[int]]:
        m_tab = [[0] * 256 for _ in range(4)]
        for value in range(256):
            f01 = q_tab[1][value]
            f5b = f01 ^ (f01 >> 2) ^ _TAB_5B[f01 & 3]
            fef = f01 ^ (f01 >> 1) ^ (f01 >> 2) ^ _TAB_EF[f01 & 3]
            m_tab[0][value] = f01 + (f5b << 8) + (fef << 16) + (fef << 24)
            m_tab[2][value] = f5b + (fef << 8) + (f01 << 16) + (fef << 24)
            f01 = q_tab[0][value]
            f5b = f01 ^ (f01 >> 2) ^ _TAB_5B[f01 & 3]
            fef = f01 ^ (f01 >> 1) ^ (f01 >> 2) ^ _TAB_EF[f01 & 3]
            m_tab[1][value] = fef + (fef << 8) + (f5b << 16) + (f01 << 24)
            m_tab[3][value] = f5b + (f01 << 8) + (fef << 16) + (f5b << 24)
        return m_tab

    # -- h function / MDS ------------------------------------------------

    @staticmethod
    def _mds_rem(p0: int, p1: int) -> int:
        """RS-matrix multiply used for the key-dependent S-box material."""
        for _ in range(8):
            top = p1 >> 24
            p1 = ((p1 << 8) & 0xFFFFFFFF) | (p0 >> 24)
            p0 = (p0 << 8) & 0xFFFFFFFF
            u = (top << 1) & 0xFFFFFFFF
            if top & 0x80:
                u ^= 0x0000014D
            p1 ^= top ^ ((u << 16) & 0xFFFFFFFF)
            u ^= top >> 1
            if top & 0x01:
                u ^= 0x0000014D >> 1
            p1 ^= ((u << 24) & 0xFFFFFFFF) | ((u << 8) & 0xFFFFFFFF)
        return p1

    @staticmethod
    def _h(q_tab, m_tab, x: int, key) -> int:
        b0 = _byte(x, 0)
        b1 = _byte(x, 1)
        b2 = _byte(x, 2)
        b3 = _byte(x, 3)
        b0 = q_tab[0][q_tab[0][b0] ^ _byte(key[1], 0)] ^ _byte(key[0], 0)
        b1 = q_tab[0][q_tab[1][b1] ^ _byte(key[1], 1)] ^ _byte(key[0], 1)
        b2 = q_tab[1][q_tab[0][b2] ^ _byte(key[1], 2)] ^ _byte(key[0], 2)
        b3 = q_tab[1][q_tab[1][b3] ^ _byte(key[1], 3)] ^ _byte(key[0], 3)
        return (m_tab[0][b0] ^ m_tab[1][b1] ^ m_tab[2][b2] ^ m_tab[3][b3])

    # -- key schedule -----------------------------------------------------

    @classmethod
    def _key_schedule(cls, q_tab, m_tab, me_key, mo_key) -> list[int]:
        l_key = [0] * 40
        for i in range(0, 40, 2):
            a = (0x01010101 * i) & 0xFFFFFFFF
            b = (a + 0x01010101) & 0xFFFFFFFF
            a = cls._h(q_tab, m_tab, a, me_key)
            b = _rotl32(cls._h(q_tab, m_tab, b, mo_key), 8)
            l_key[i] = (a + b) & 0xFFFFFFFF
            l_key[i + 1] = _rotl32((a + 2 * b) & 0xFFFFFFFF, 9)
        return l_key

    @staticmethod
    def _sbox_tables(q_tab, m_tab, s_key, me_key, mo_key) -> list[list[int]]:
        mk_tab = [[0] * 256 for _ in range(4)]
        for value in range(256):
            mk_tab[0][value] = m_tab[0][
                q_tab[0][q_tab[0][value] ^ _byte(s_key[1], 0)]
                ^ _byte(s_key[0], 0)]
            mk_tab[1][value] = m_tab[1][
                q_tab[0][q_tab[1][value] ^ _byte(s_key[1], 1)]
                ^ _byte(s_key[0], 1)]
            mk_tab[2][value] = m_tab[2][
                q_tab[1][q_tab[0][value] ^ _byte(s_key[1], 2)]
                ^ _byte(s_key[0], 2)]
            mk_tab[3][value] = m_tab[3][
                q_tab[1][q_tab[1][value] ^ _byte(s_key[1], 3)]
                ^ _byte(s_key[0], 3)]
        return mk_tab

    # -- block operations -------------------------------------------------

    def encrypt_block(self, block: bytes) -> bytes:
        a, b, c, d = struct.unpack("<4L", block)
        x0 = a ^ self.l_key[0]
        x1 = b ^ self.l_key[1]
        x2 = c ^ self.l_key[2]
        x3 = d ^ self.l_key[3]
        mk = self.mk_tab
        l_key = self.l_key
        for i in range(8):
            t1 = (mk[0][_byte(x1, 3)] ^ mk[1][_byte(x1, 0)]
                  ^ mk[2][_byte(x1, 1)] ^ mk[3][_byte(x1, 2)])
            t0 = (mk[0][_byte(x0, 0)] ^ mk[1][_byte(x0, 1)]
                  ^ mk[2][_byte(x0, 2)] ^ mk[3][_byte(x0, 3)])
            x2 = _rotr32(x2 ^ ((t0 + t1 + l_key[4 * i + 8]) & 0xFFFFFFFF), 1)
            x3 = (_rotl32(x3, 1)
                  ^ ((t0 + 2 * t1 + l_key[4 * i + 9]) & 0xFFFFFFFF))
            t1 = (mk[0][_byte(x3, 3)] ^ mk[1][_byte(x3, 0)]
                  ^ mk[2][_byte(x3, 1)] ^ mk[3][_byte(x3, 2)])
            t0 = (mk[0][_byte(x2, 0)] ^ mk[1][_byte(x2, 1)]
                  ^ mk[2][_byte(x2, 2)] ^ mk[3][_byte(x2, 3)])
            x0 = _rotr32(x0 ^ ((t0 + t1 + l_key[4 * i + 10]) & 0xFFFFFFFF), 1)
            x1 = (_rotl32(x1, 1)
                  ^ ((t0 + 2 * t1 + l_key[4 * i + 11]) & 0xFFFFFFFF))
        return struct.pack(
            "<4L",
            x2 ^ l_key[4], x3 ^ l_key[5], x0 ^ l_key[6], x1 ^ l_key[7])

    def decrypt_block(self, block: bytes) -> bytes:
        a, b, c, d = struct.unpack("<4L", block)
        x0 = a ^ self.l_key[4]
        x1 = b ^ self.l_key[5]
        x2 = c ^ self.l_key[6]
        x3 = d ^ self.l_key[7]
        mk = self.mk_tab
        l_key = self.l_key
        for i in range(7, -1, -1):
            t1 = (mk[0][_byte(x1, 3)] ^ mk[1][_byte(x1, 0)]
                  ^ mk[2][_byte(x1, 1)] ^ mk[3][_byte(x1, 2)])
            t0 = (mk[0][_byte(x0, 0)] ^ mk[1][_byte(x0, 1)]
                  ^ mk[2][_byte(x0, 2)] ^ mk[3][_byte(x0, 3)])
            x2 = (_rotl32(x2, 1)
                  ^ ((t0 + t1 + l_key[4 * i + 10]) & 0xFFFFFFFF))
            x3 = _rotr32(
                x3 ^ ((t0 + 2 * t1 + l_key[4 * i + 11]) & 0xFFFFFFFF), 1)
            t1 = (mk[0][_byte(x3, 3)] ^ mk[1][_byte(x3, 0)]
                  ^ mk[2][_byte(x3, 1)] ^ mk[3][_byte(x3, 2)])
            t0 = (mk[0][_byte(x2, 0)] ^ mk[1][_byte(x2, 1)]
                  ^ mk[2][_byte(x2, 2)] ^ mk[3][_byte(x2, 3)])
            x0 = (_rotl32(x0, 1)
                  ^ ((t0 + t1 + l_key[4 * i + 8]) & 0xFFFFFFFF))
            x1 = _rotr32(
                x1 ^ ((t0 + 2 * t1 + l_key[4 * i + 9]) & 0xFFFFFFFF), 1)
        return struct.pack(
            "<4L",
            x2 ^ l_key[0], x3 ^ l_key[1], x0 ^ l_key[2], x1 ^ l_key[3])


# Key expansion is deterministic and the container key is fixed, so it is
# done once per process.  The expanded tables are read-only afterwards.
_KEY_CACHE: dict[bytes, _TwofishKey] = {}


def _twofish(key: bytes) -> _TwofishKey:
    state = _KEY_CACHE.get(key)
    if state is None:
        state = _TwofishKey(key)
        _KEY_CACHE[key] = state
    return state


# ---------------------------------------------------------------------------
# CMAC / CTR / EAX
# ---------------------------------------------------------------------------

def _xor(a: bytes, b: bytes) -> bytes:
    return bytes(x ^ y for x, y in zip(a, b))


def _left_shift_one(bitstring: bytes) -> bytes:
    out = bytearray(len(bitstring))
    carry = 0
    for i in reversed(range(len(bitstring))):
        out[i] = ((bitstring[i] << 1) & 0xFF) | carry
        carry = (bitstring[i] & 0x80) >> 7
    return bytes(out)


class _Cmac:
    """CMAC over any 16-byte block cipher (RFC 4493 subkeys)."""

    __slots__ = ("_encrypt", "k1", "k2")

    def __init__(self, encrypt):
        self._encrypt = encrypt
        l_value = encrypt(bytes(BLOCK))
        k1 = _left_shift_one(l_value)
        if l_value[0] & 0x80:
            k1 = _xor(k1, b"\x00" * 15 + bytes([0x87]))
        k2 = _left_shift_one(k1)
        if k1[0] & 0x80:
            k2 = _xor(k2, b"\x00" * 15 + bytes([0x87]))
        self.k1 = k1
        self.k2 = k2

    def digest(self, data: bytes) -> bytes:
        blocks = [data[i:i + BLOCK] for i in range(0, len(data), BLOCK)]
        if not blocks:
            blocks = [b""]
        tail = blocks.pop()
        if len(tail) == BLOCK:
            last = _xor(tail, self.k1)
        else:
            padded = tail + b"\x80"
            padded += b"\x00" * (BLOCK - len(padded))
            last = _xor(padded, self.k2)
        state = bytes(BLOCK)
        for block in blocks:
            state = self._encrypt(_xor(state, block))
        return self._encrypt(_xor(state, last))


class _Eax:
    """EAX authenticated encryption (Bellare-Rogaway-Wagner)."""

    __slots__ = ("_encrypt", "_cmac")

    def __init__(self, encrypt):
        self._encrypt = encrypt
        self._cmac = _Cmac(encrypt)

    def _omac(self, prefix: int, data: bytes) -> bytes:
        return self._cmac.digest(
            b"\x00" * (BLOCK - 1) + bytes([prefix]) + data)

    def _ctr(self, nonce_tag: bytes, data: bytes) -> bytes:
        counter = bytearray(nonce_tag)
        out = bytearray()
        offset = 0
        while offset < len(data):
            keystream = self._encrypt(bytes(counter))
            for i in range(BLOCK - 1, -1, -1):  # big-endian increment
                counter[i] = (counter[i] + 1) & 0xFF
                if counter[i]:
                    break
            block = data[offset:offset + BLOCK]
            out.extend(x ^ y for x, y in zip(block, keystream[:len(block)]))
            offset += BLOCK
        return bytes(out)

    def encrypt(self, nonce: bytes, plaintext: bytes,
                aad: bytes = b"") -> tuple[bytes, bytes]:
        nonce_tag = self._omac(0x00, nonce)
        header_tag = self._omac(0x01, aad)
        ciphertext = self._ctr(nonce_tag, plaintext)
        cipher_tag = self._omac(0x02, ciphertext)
        tag = _xor(_xor(nonce_tag, header_tag), cipher_tag)
        return ciphertext, tag

    def decrypt(self, nonce: bytes, ciphertext: bytes, tag: bytes,
                aad: bytes = b"") -> bytes:
        nonce_tag = self._omac(0x00, nonce)
        plaintext = self._ctr(nonce_tag, ciphertext)
        header_tag = self._omac(0x01, aad)
        cipher_tag = self._omac(0x02, ciphertext)
        expected = _xor(_xor(nonce_tag, header_tag), cipher_tag)
        if expected != tag:
            raise PktFormatError("EAX authentication failed (wrong key, "
                                 "corrupted file, or a newer format)")
        return plaintext


def _cbc_decrypt(key_state: _TwofishKey, data: bytes, iv: bytes) -> bytes:
    """Legacy Twofish-CBC decryption (Packet Tracer <= 7.2.1 saves)."""
    if len(data) % BLOCK:
        raise PktFormatError("legacy CBC payload is not block-aligned")
    out = bytearray()
    previous = iv
    for offset in range(0, len(data), BLOCK):
        block = data[offset:offset + BLOCK]
        plain = key_state.decrypt_block(block)
        out.extend(_xor(plain, previous))
        previous = block
    return bytes(out)


# ---------------------------------------------------------------------------
# Obfuscation stages
# ---------------------------------------------------------------------------

def _stage_outer_decode(data: bytes) -> bytes:
    length = len(data)
    return bytes(
        data[length - 1 - i] ^ ((length - i * length) & 0xFF)
        for i in range(length))


def _stage_outer_encode(blob: bytes) -> bytes:
    length = len(blob)
    out = bytearray(length)
    for i in range(length):
        out[length - 1 - i] = blob[i] ^ ((length - i * length) & 0xFF)
    return bytes(out)


def _stage_inner(data: bytes) -> bytes:
    """XOR each byte with ``(length - i) & 0xFF``; its own inverse."""
    length = len(data)
    return bytes(b ^ ((length - i) & 0xFF) for i, b in enumerate(data))


def _qt_compress(xml: bytes) -> bytes:
    return struct.pack(">I", len(xml)) + zlib.compress(xml)


def _qt_uncompress(blob: bytes) -> bytes:
    if len(blob) < 6:
        raise PktFormatError("compressed payload is too short")
    declared = struct.unpack(">I", blob[:4])[0]
    if declared > MAX_XML_BYTES:
        raise PktFormatError(
            f"declared size {declared} exceeds the {MAX_XML_BYTES} byte cap")
    decompressor = zlib.decompressobj()
    data = decompressor.decompress(blob[4:], declared)
    data += decompressor.flush()
    if not data.startswith(b"<"):
        raise PktFormatError("payload does not decompress to XML")
    return data[:declared]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Characters XML 1.0 does not allow anywhere, not even escaped.  Packet
# Tracer writes them in banner delimiters (^C, 0x03) and several of its own
# sample saves carry them in a device's startup config, so they have to be
# dealt with on the way in *and* on the way out: one in a harvested template
# block makes that block unparseable, and one in a generated config line makes
# the whole .pkt unopenable.
_XML_ILLEGAL = re.compile(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def xml_safe(data: bytes) -> bytes:
    """Replace XML-illegal control characters so a document stays parseable."""
    if isinstance(data, str):
        return _XML_ILLEGAL.sub(b" ", data.encode("utf-8", "replace"))
    return _XML_ILLEGAL.sub(b" ", data)


def is_pkt(data: bytes) -> bool:
    """True when the buffer looks like a Packet Tracer save container."""
    return len(data) >= MIN_PKT_BYTES and not data.startswith(b"<?xml")


def decrypt_pkt(data: bytes) -> bytes:
    """Decode a .pkt/.pka container and return the XML bytes.

    Raises :class:`PktFormatError` when the buffer is not a save file this
    codec can read.
    """
    if not isinstance(data, (bytes, bytearray)):
        raise PktFormatError("expected the raw file bytes")
    data = bytes(data)
    if len(data) < MIN_PKT_BYTES:
        raise PktFormatError(f"file is too small ({len(data)} bytes)")
    if data.lstrip()[:1] == b"<":
        raise PktFormatError("this file is plain XML, not an encrypted save")
    stage1 = _stage_outer_decode(data)
    key_state = _twofish(PT_KEY)
    body, tag = stage1[:-BLOCK], stage1[-BLOCK:]
    errors = []
    try:
        decrypted = _Eax(key_state.encrypt_block).decrypt(PT_NONCE, body, tag)
        return _qt_uncompress(_stage_inner(decrypted))
    except PktFormatError as exc:
        errors.append(f"EAX: {exc}")
    # Packet Tracer 7.2.1 and older used CBC for the same container.
    try:
        decrypted = _cbc_decrypt(key_state, body, PT_NONCE)
        return _qt_uncompress(_stage_inner(decrypted))
    except Exception as exc:  # noqa: BLE001 - reported together below
        errors.append(f"CBC: {exc}")
    raise PktFormatError("could not decode the file (" + "; ".join(errors) + ")")


def encrypt_pkt(xml: bytes, *, validator=None) -> bytes:
    """Encode XML bytes into a .pkt container.

    ``validator`` (optional) is called with the XML and may raise to refuse
    obviously broken input before anything is encrypted.
    """
    if isinstance(xml, str):
        xml = xml.encode("utf-8")
    if not xml:
        raise PktFormatError("refusing to encode an empty document")
    if validator is not None:
        validator(xml)
    key_state = _twofish(PT_KEY)
    compressed = _stage_inner(_qt_compress(xml))
    ciphertext, tag = _Eax(key_state.encrypt_block).encrypt(
        PT_NONCE, compressed)
    return _stage_outer_encode(ciphertext + tag)


def pkt_xml_summary(xml: bytes) -> dict:
    """Structural facts about a decrypted save, for reports and the UI.

    Configuration text is deliberately not included: only counts, names,
    models and link endpoints.
    """
    import re

    text = xml if isinstance(xml, bytes) else xml.encode("utf-8")

    def _one(pattern: bytes, source: bytes, default: str = "") -> str:
        match = re.search(pattern, source)
        return match.group(1).decode("utf-8", "replace") if match else default

    devices = re.findall(rb"<DEVICE>.*?</DEVICE>", text, re.S)
    inventory = []
    for block in devices:
        inventory.append({
            "name": _one(rb"<NAME translate=\"true\">([^<]*)</NAME>",
                         block, ""),
            "model": _one(
                rb"<TYPE customModel=\"[^\"]*\" model=\"([^\"]*)\"",
                block, ""),
            "kind": _one(
                rb"<TYPE customModel=\"[^\"]*\" model=\"[^\"]*\">([^<]*)<",
                block, ""),
            "sysName": _one(rb"<SYS_NAME>([^<]*)</SYS_NAME>", block, ""),
            "configLines": len(re.findall(rb"<LINE>", block)),
        })
    links = re.findall(rb"<LINK>.*?</LINK>", text, re.S)
    endpoints = []
    for block in links:
        ports = re.findall(rb"<PORT>([^<]*)</PORT>", block)
        endpoints.append({
            "type": _one(rb"<TYPE>([^<]*)</TYPE>", block, ""),
            "from": _one(rb"<FROM>([^<]*)</FROM>", block, ""),
            "fromPort": ports[0].decode("utf-8", "replace") if ports else "",
            "to": _one(rb"<TO>([^<]*)</TO>", block, ""),
            "toPort": ports[1].decode("utf-8", "replace") if len(ports) > 1
            else "",
        })
    return {
        "version": _one(rb"<VERSION>([^<]*)</VERSION>", text, ""),
        "root": _one(rb"<([A-Za-z0-9_]+)>", text, ""),
        "deviceCount": len(devices),
        "linkCount": len(links),
        "devices": inventory,
        "links": endpoints,
    }


def twofish_selftest() -> dict:
    """Check the block cipher against the published test vector."""
    expected = "9F589F5CF6122C32B6BFEC2F2AE8C35A"
    cipher = _twofish(bytes(BLOCK))
    got = cipher.encrypt_block(bytes(BLOCK)).hex().upper()
    back = cipher.decrypt_block(bytes.fromhex(expected))
    return {
        "vector": expected,
        "encrypt": got,
        "ok": got == expected and back == bytes(BLOCK),
    }


def codec_selftest() -> dict:
    """Block-cipher vector plus a container round trip."""
    started = time.perf_counter()
    twofish = twofish_selftest()
    sample = (b"<PACKETTRACER5><VERSION>9.0.0.0810</VERSION>"
              b"<PROBE>" + bytes(range(256)) * 4 + b"</PROBE></PACKETTRACER5>")
    encoded = encrypt_pkt(sample)
    decoded = decrypt_pkt(encoded)
    return {
        "ok": bool(twofish["ok"] and decoded == sample),
        "twofish": twofish,
        "roundTrip": decoded == sample,
        "ms": round((time.perf_counter() - started) * 1000, 1),
    }


if __name__ == "__main__":  # pragma: no cover - manual smoke check
    import json
    print(json.dumps(codec_selftest(), indent=2))
