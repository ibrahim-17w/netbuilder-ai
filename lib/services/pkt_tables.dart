// GENERATED FILE - do not edit by hand.
//
// The Twofish tables from sidecar/pkt_codec.py, emitted verbatim so the Dart
// codec and the Python codec cannot drift apart. See
// tool/pkt_codec_port.dart for how the rest of the port is verified.
//
// ignore_for_file: lines_longer_than_80_chars

const List<int> kQTiles = [
  8, 1, 7, 13, 6, 15, 3, 2, 0, 11, 5, 9, 14, 12, 10, 4,
  2, 8, 11, 13, 15, 7, 6, 14, 3, 1, 9, 4, 0, 10, 12, 5,
  14, 12, 11, 8, 1, 2, 3, 5, 15, 4, 10, 6, 7, 0, 9, 13,
  1, 14, 2, 11, 4, 12, 3, 7, 6, 13, 10, 5, 15, 9, 0, 8,
  11, 10, 5, 14, 6, 13, 9, 0, 12, 8, 15, 3, 2, 4, 7, 1,
  4, 12, 7, 5, 1, 6, 9, 10, 0, 14, 13, 8, 2, 11, 3, 15,
  13, 7, 15, 4, 1, 2, 6, 14, 9, 11, 3, 0, 8, 5, 12, 10,
  11, 9, 5, 1, 12, 3, 13, 14, 6, 4, 7, 15, 2, 0, 8, 10,
];

/// _Q_TABLES flattened as [a][b][v] -> index ((a * 2) + b) * 16 + v.
const List<int> kT5b = [
  0, 90, 180, 238,
];

const List<int> kTef = [
  0, 238, 180, 90,
];

const List<int> kRor4 = [
  0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15,
];

const List<int> kAshx = [
  0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 5, 14, 7,
];
