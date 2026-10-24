import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/pkt_analysis_chat.dart';
import 'package:net_builder/services/session_state.dart';

Map<String, dynamic> _report() => {
  'summary': {'device_count': 3, 'links': 2},
  'linkCount': 2,
  'devices': [
    {
      'name': 'R0',
      'type': 'Router',
      'interfaces': [
        {'name': 'Serial0/2/0', 'status': 'administratively down', 'ip': ''},
        {'name': 'Serial0/2/1', 'status': 'administratively down', 'ip': ''},
      ],
      'findings': [
        {
          'id': 'R0:offline:link:1',
          'kind': 'connected_interface_down',
          'severity': 'medium',
          'device': 'R0 <-> R1',
          'text':
              'Cabled link R0 Serial0/2/0 <-> R1 Serial0/2/0 has a '
              'saved-down endpoint. If active, check both interfaces and '
              'serial clocking. If unused, leaving it down is normal.',
          'fix_cli': [],
          'repairs': [
            {
              'id': 'R0:offline:link:1',
              'device': 'R0',
              'fix_cli': ['interface Serial0/2/0', 'no shutdown'],
            },
            {
              'id': 'R0:offline:link:1',
              'device': 'R1',
              'fix_cli': ['interface Serial0/2/0', 'no shutdown'],
            },
          ],
        },
        {
          'id': 'R0:offline:link:2',
          'kind': 'connected_interface_down',
          'severity': 'medium',
          'device': 'R0 <-> R2',
          'text':
              'Cabled link R0 Serial0/2/1 <-> R2 Serial0/2/1 has a '
              'saved-down endpoint. If active, check both interfaces.',
          'fix_cli': [],
          'repairs': [
            {
              'id': 'R0:offline:link:2',
              'device': 'R0',
              'fix_cli': ['interface Serial0/2/1', 'no shutdown'],
            },
            {
              'id': 'R0:offline:link:2',
              'device': 'R2',
              'fix_cli': ['interface Serial0/2/1', 'no shutdown'],
            },
          ],
        },
      ],
    },
    {'name': 'R1', 'type': 'Router', 'interfaces': [], 'findings': []},
    {'name': 'R2', 'type': 'Router', 'interfaces': [], 'findings': []},
  ],
  'links': [
    {'a': 'R0', 'aIf': 'Serial0/2/0', 'b': 'R1', 'bIf': 'Serial0/2/0'},
    {'a': 'R0', 'aIf': 'Serial0/2/1', 'b': 'R2', 'bIf': 'Serial0/2/1'},
  ],
};

void main() {
  late Map<String, dynamic> analysis;
  setUp(() {
    analysis = PktAnalysisChat.snapshot(
      _report(),
      path: r'C:\labs\office.pkt',
      name: 'office.pkt',
    );
  });

  test('initial text is a report and does not create repair actions', () {
    final text = PktAnalysisChat.reportText(analysis);
    expect(text, contains('3 devices and 2 links'));
    expect(text, contains('2 conditional'));
    expect(text, contains('R0 <-> R1'));
    expect(text, contains('nothing has been changed'));
    expect(text, isNot(contains('approve a fix below')));
  });

  test('shutdown explanation distinguishes active links from spare ports', () {
    final reply = PktAnalysisChat.answer(
      'why no shutdown is important?',
      analysis,
    );
    expect(reply, isNotNull);
    expect(reply!.text, contains('unused spare port should usually stay shut'));
    expect(reply.text, contains('2 cabled link(s)'));
    expect(reply.text, contains('clock rate'));
    expect(
      reply.fixes,
      isEmpty,
      reason: 'a why question must never become a repair action',
    );
  });

  test('VLAN 1 shutdown with no management IP is explained as intentional', () {
    final reply = PktAnalysisChat.answer('why is VLAN 1 shut down?', analysis);
    expect(reply, isNotNull);
    expect(reply!.text, contains('separate from the physical switch ports'));
    expect(reply.text, contains('does not count an unaddressed VLAN 1 SVI'));
    expect(reply.fixes, isEmpty);
  });

  test('a vague request for more explanation asks which finding', () {
    final reply = PktAnalysisChat.answer(
      'explain more about this issue',
      analysis,
    );
    expect(reply, isNotNull);
    expect(reply!.text, contains('please name the device or interface'));
  });

  test('a specific explicit repair produces one reviewable batch card', () {
    final reply = PktAnalysisChat.answer('fix R0 Serial0/2/0', analysis);
    expect(reply, isNotNull);
    expect(reply!.fixes, hasLength(2));
    expect(reply.fixes.map((f) => f['device']), containsAll(['R0', 'R1']));
    expect(reply.text, contains('no shutdown'));
    expect(reply.text, contains('original file stays untouched'));
  });

  test('an ambiguous explicit repair asks which finding to change', () {
    final reply = PktAnalysisChat.answer('fix R0', analysis);
    expect(reply, isNotNull);
    expect(reply!.text, contains('Please name one device and interface'));
    expect(reply.fixes, isEmpty);
  });

  test('a what-if does not become an action proposal', () {
    final reply = PktAnalysisChat.answer('what if we fix R0?', analysis);
    expect(reply, isNull);
  });

  test('overview questions do not accidentally trigger a repair', () {
    final reply = PktAnalysisChat.answer('what should I fix first?', analysis);
    expect(reply, isNotNull);
    expect(reply!.text, contains('Offline review'));
    expect(reply.fixes, isEmpty);
  });

  test(
    'scan snapshot survives SessionState persistence and informs models',
    () {
      final saved = SessionState()
          .withCaptureAnalysis(
            path: r'C:\labs\office.pkt',
            name: 'office.pkt',
            analysisJson: jsonEncode(analysis),
          )
          .encode();
      final restored = SessionState.decode(saved);
      expect(restored.capturePath, r'C:\labs\office.pkt');
      expect(restored.captureName, 'office.pkt');
      expect(restored.captureAnalysisJson, isNotEmpty);
      final prompt = restored.promptBlock(userText: 'why is the link down?');
      expect(prompt, contains('R0 <-> R1'));
      expect(prompt, contains('read-only snapshot'));
      expect(prompt, isNot(contains(r'C:\labs\office.pkt')));
    },
  );

  group('reachability is reasoned over the scanned file', () {
    // A small LAN whose two PCs are cabled through SW0, with real addresses
    // in the interface rows - the shape a clean office-lab scan has.
    Map<String, dynamic> lanScan({
      Map<String, String> overrideIp = const {},
      Map<String, String> overrideStatus = const {},
      List<Map<String, String>> links = const [
        {
          'a': 'PC1',
          'aIf': 'FastEthernet0',
          'b': 'SW0',
          'bIf': 'FastEthernet0/1',
        },
        {
          'a': 'PC2',
          'aIf': 'FastEthernet0',
          'b': 'SW0',
          'bIf': 'FastEthernet0/2',
        },
      ],
    }) {
      String ip(String device) =>
          overrideIp[device] ??
          (device == 'PC1' ? '192.168.1.10' : '192.168.1.11');
      String status(String device) =>
          overrideStatus[device] ?? (device == 'PC1' ? 'up' : 'up');
      return PktAnalysisChat.snapshot(
        {
          'summary': {'device_count': 3, 'links': links.length},
          'devices': [
            {
              'name': 'PC1',
              'type': 'PC',
              'interfaces': [
                {
                  'name': 'FastEthernet0',
                  'status': status('PC1'),
                  'ip': ip('PC1'),
                },
              ],
              'findings': [],
            },
            {
              'name': 'PC2',
              'type': 'PC',
              'interfaces': [
                {
                  'name': 'FastEthernet0',
                  'status': status('PC2'),
                  'ip': ip('PC2'),
                },
              ],
              'findings': [],
            },
            {
              'name': 'SW0',
              'type': 'Switch',
              'interfaces': [
                {'name': 'FastEthernet0/1', 'status': 'up', 'ip': ''},
                {'name': 'FastEthernet0/2', 'status': 'up', 'ip': ''},
              ],
              'findings': [],
            },
          ],
          'links': links,
        },
        path: r'C:\labs\lan.pkt',
        name: 'lan.pkt',
      );
    }

    test('two addressed, cabled hosts get the honest can-prove answer', () {
      final reply = PktAnalysisChat.answer(
        "why can't PC1 ping PC2?",
        lanScan(),
      );
      expect(reply, isNotNull);
      expect(reply!.text, contains('192.168.1.10'));
      expect(reply.text, contains('PC1 -> SW0 -> PC2'));
      expect(
        reply.text,
        contains('cannot prove a live ping'),
        reason: 'the offline scan states its own limit',
      );
    });

    test('an unaddressed endpoint is named with its fix', () {
      final reply = PktAnalysisChat.answer(
        "why can't PC2 ping PC1?",
        lanScan(overrideIp: const {'PC2': ''}),
      );
      expect(reply, isNotNull);
      expect(reply!.text, contains('PC2 has no configured address'));
      expect(reply.text, contains('IP Configuration'));
    });

    test(
      'no cable path between the two ends is reported, with who IS cabled',
      () {
        final reply = PktAnalysisChat.answer(
          "why can't PC1 ping PC2?",
          lanScan(
            links: const [
              {
                'a': 'PC1',
                'aIf': 'FastEthernet0',
                'b': 'SW0',
                'bIf': 'FastEthernet0/1',
              },
            ],
          ),
        );
        expect(reply, isNotNull);
        expect(reply!.text, contains('no cable path between PC1 and PC2'));
        expect(reply.text, contains('PC2 has no cable at all'));
      },
    );

    test('an admin-down interface on the path names the exact port', () {
      final reply = PktAnalysisChat.answer(
        "why can't PC1 ping PC2?",
        lanScan(overrideStatus: const {'PC1': 'administratively down'}),
      );
      expect(reply, isNotNull);
      expect(
        reply!.text,
        contains('PC1 FastEthernet0 is administratively down'),
      );
      expect(reply.text, contains('no shutdown'));
    });

    test('a ping question about a non-device stays with the other answers', () {
      expect(
        PktAnalysisChat.answer("why can't PC1 ping the internet?", lanScan()),
        isNull,
      );
    });
  });
}
