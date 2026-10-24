import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/pkt_scan_diff.dart';

/// The diff says only what two scans can prove: devices, addresses per
/// device+interface, cable endpoint pairs, findings by their stable text.
void main() {
  Map<String, dynamic> snapshot({
    List<Map<String, dynamic>> devices = const [],
    List<Map<String, dynamic>> interfaces = const [],
    List<Map<String, dynamic>> links = const [],
    List<Map<String, dynamic>> findings = const [],
  }) => {
    'devices': devices,
    'interfaces': interfaces,
    'links': links,
    'findings': findings,
  };

  test('added and removed devices are named', () {
    final d = PktScanDiff.diff(
      snapshot(
        devices: [
          {'name': 'R1'},
          {'name': 'SW1'},
        ],
      ),
      snapshot(
        devices: [
          {'name': 'R1'},
          {'name': 'R2'},
        ],
      ),
    );
    expect(d.devicesAdded, ['R2']);
    expect(d.devicesRemoved, ['SW1']);
  });

  test('an address move is reported with both values, per interface', () {
    final d = PktScanDiff.diff(
      snapshot(
        interfaces: [
          {'device': 'R1', 'name': 'g0/0', 'ip': '10.0.0.1'},
          {'device': 'PC1', 'name': 'f0', 'ip': ''},
        ],
      ),
      snapshot(
        interfaces: [
          {'device': 'R1', 'name': 'g0/0', 'ip': '10.0.0.1'},
          {'device': 'R1', 'name': 'g0/1', 'ip': ''},
          {'device': 'PC1', 'name': 'f0', 'ip': '192.168.1.10'},
        ],
      ),
    );
    expect(d.addressChanges, hasLength(1));
    final c = d.addressChanges.single;
    expect(c.device, 'PC1');
    expect(c.before, '');
    expect(c.after, '192.168.1.10');
  });

  test('interface status flapping is not a diff', () {
    final d = PktScanDiff.diff(
      snapshot(
        interfaces: [
          {'device': 'R1', 'name': 'g0/0', 'ip': '10.0.0.1', 'status': 'up'},
        ],
      ),
      snapshot(
        interfaces: [
          {
            'device': 'R1',
            'name': 'g0/0',
            'ip': '10.0.0.1',
            'status': 'administratively down',
          },
        ],
      ),
    );
    expect(d.isEmpty, isTrue, reason: 'state is not a design change');
  });

  test('cables are compared as endpoint pairs', () {
    final d = PktScanDiff.diff(
      snapshot(
        links: [
          {'a': 'R1', 'aIf': 'g0/0', 'b': 'SW1', 'bIf': 'f0/1'},
        ],
      ),
      snapshot(
        links: [
          {'a': 'R1', 'aIf': 'g0/1', 'b': 'SW1', 'bIf': 'f0/2'},
        ],
      ),
    );
    expect(d.linksAdded, ['R1:g0/1 <-> SW1:f0/2']);
    expect(d.linksRemoved, ['R1:g0/0 <-> SW1:f0/1']);
  });

  test('findings compare by text, not per-scan ids', () {
    final d = PktScanDiff.diff(
      snapshot(
        findings: [
          {'id': 'R1:offline:1', 'text': 'g0/1 is administratively down'},
        ],
      ),
      snapshot(
        findings: [
          {'id': 'R1:offline:7', 'text': 'g0/1 is administratively down'},
          {'id': 'R1:offline:8', 'text': 'duplicate address 10.0.0.1'},
        ],
      ),
    );
    expect(d.findingsCleared, isEmpty);
    expect(d.findingsIntroduced, ['duplicate address 10.0.0.1']);
  });

  test('the markdown says when the files read the same', () {
    final same = snapshot(
      devices: [
        {'name': 'R1'},
      ],
    );
    final text = PktScanDiff.toMarkdown(
      PktScanDiff.diff(same, same),
      beforeName: 'a',
      afterName: 'b',
    );
    expect(text, contains('**a -> b**'));
    expect(text, contains('No differences'));
  });

  group('PktScanDiffRequest.read', () {
    test('two named paths are both sides', () {
      final r = PktScanDiffRequest.read(
        r'diff C:\labs\a.pkt and C:\labs\b.pkt',
        currentCapturePath: null,
        currentCaptureName: null,
      );
      expect(r, isNotNull);
      expect(r!.pathA, r'C:\labs\a.pkt');
      expect(r.pathB, r'C:\labs\b.pkt');
      expect(r.nameA, 'a');
      expect(r.nameB, 'b');
    });

    test('one path plus this-file pairs with the current capture', () {
      final r = PktScanDiffRequest.read(
        r'compare this file with C:\labs\after.pkt',
        currentCapturePath: r'C:\before\lab.pkt',
        currentCaptureName: 'lab.pkt',
      );
      expect(r, isNotNull);
      expect(r!.pathA, r'C:\before\lab.pkt');
      expect(r.pathB, r'C:\labs\after.pkt');
      expect(r.nameA, 'lab.pkt');
    });

    test('no verb or no paths is not a diff request', () {
      expect(
        PktScanDiffRequest.read(
          r'build C:\labs\a.pkt',
          currentCapturePath: null,
          currentCaptureName: null,
        ),
        isNull,
      );
      expect(
        PktScanDiffRequest.read(
          'diff the two scans',
          currentCapturePath: null,
          currentCaptureName: null,
        ),
        isNull,
      );
    });

    test('a non-diff message never matches', () {
      expect(
        PktScanDiffRequest.read(
          'add a switch and compare routing options',
          currentCapturePath: null,
          currentCaptureName: null,
        ),
        isNull,
      );
    });
  });
}
