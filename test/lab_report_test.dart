import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/lab_report.dart';
import 'package:net_builder/services/pkt_analysis_chat.dart';

/// The lab report invents nothing: every section comes from a generator
/// that already ran for the user, and a missing section says so in words.
void main() {
  final plan = NetworkIntent.parseSimple(
    'p',
    '2 routers 1 switch 4 pcs in vlan 10 with a dhcp server',
  );

  test('the report assembles plan, review, builds, scan and guide', () {
    // Findings ride the device entries in a scan report - that is where
    // PktAnalysisChat.snapshot reads them from.
    final scan = PktAnalysisChat.snapshot(
      {
        'summary': {'device_count': 7, 'links': 6},
        'devices': [
          {
            'name': 'R1',
            'type': 'Router',
            'findings': [
              {
                'id': 'R1:offline:1',
                'severity': 'high',
                'text': 'g0/1 is administratively down',
              },
            ],
          },
        ],
      },
      path: r'C:\labs\office.pkt',
      name: 'office.pkt',
    );
    final text = LabReport.markdown(
      intent: plan,
      target: 'packet-tracer',
      artifacts: const [
        (name: 'routers-switches.pkt', note: 'build verified against the file'),
      ],
      scanAnalysis: scan,
    );
    expect(text, startsWith('# Lab report - '));
    expect(text, contains('## The plan'));
    expect(text, contains('2 routers'));
    expect(text, contains('VLANs: 10'));
    expect(text, contains('| Device | Interface | Address |'));
    expect(text, contains('## Design review'));
    expect(text, contains('/100'));
    expect(text, contains('routers-switches.pkt'));
    expect(text, contains('build verified against the file'));
    expect(text, contains('## Offline scan'));
    expect(text, contains('g0/1 is administratively down'));
    expect(text, contains('## How to build it'));
    expect(text, contains('Build guide'));
  });

  test('missing evidence is stated, not implied', () {
    final text = LabReport.markdown(
      intent: plan,
      target: 'packet-tracer',
      artifacts: const [],
    );
    expect(text, contains('No .pkt was built in this conversation yet'));
    expect(text, contains('No .pkt was analyzed'));
  });

  test('a plan without addressing or VLANs skips those rows', () {
    // Built directly: the parser auto-generates addressing for a brief,
    // and this test is about a plan that genuinely has none.
    const bare = NetworkIntent(
      projectName: 'bare',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
      ],
    );
    final text = LabReport.markdown(
      intent: bare,
      target: 'packet-tracer',
      artifacts: const [],
    );
    expect(text, isNot(contains('| Device | Interface | Address |')));
    expect(text, isNot(contains('VLANs:')));
  });

  group('LabReportRequest.matches', () {
    test('report asks are caught', () {
      const yes = [
        'export a lab report',
        'lab report',
        '/report',
        'generate a lab report',
        'write the lab report',
        'make me a lab report',
      ];
      for (final text in yes) {
        expect(LabReportRequest.matches(text), isTrue, reason: text);
      }
    });

    test('everything else is not a report request', () {
      const no = [
        'build the .pkt',
        'export the .pkt',
        'what is a lab?',
        'show me the report on routers',
        'report the bug',
        'add a server',
      ];
      for (final text in no) {
        expect(LabReportRequest.matches(text), isFalse, reason: text);
      }
    });
  });
}
