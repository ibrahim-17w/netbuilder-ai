import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/widgets/verification_report.dart';

void main() {
  testWidgets('renders summary and one row per test with status chips',
      (tester) async {
    final report = {
      'passed': 1,
      'failed': 1,
      'skipped': 1,
      'total': 3,
      'summary': '1 passed, 1 failed, 1 skipped',
      'tests': [
        {
          'src': 'PC1',
          'dst': 'R1',
          'kind': 'gateway',
          'detail': 'ping 192.168.1.1: replies',
          'status': 'passed',
          'evidence': 'Reply from 192.168.1.1: bytes=32 TTL=128',
        },
        {
          'src': 'PC1',
          'dst': 'SRV1',
          'kind': 'service',
          'detail': 'ping 192.168.1.20: no reply',
          'status': 'failed',
        },
        {
          'src': '',
          'dst': '',
          'kind': 'custom',
          'detail': 'check the printer by hand',
          'status': 'skipped',
        },
      ],
    };

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: VerificationReport(report: report))),
    );

    expect(find.text('1 passed, 1 failed, 1 skipped'), findsOneWidget);
    expect(find.text('PASS'), findsOneWidget);
    expect(find.text('FAIL'), findsOneWidget);
    expect(find.text('SKIP'), findsOneWidget);
    expect(find.textContaining('PC1 -> R1'), findsOneWidget);
    expect(find.textContaining('PC1 -> SRV1'), findsOneWidget);
    expect(find.textContaining('check the printer by hand'), findsOneWidget);
  });

  testWidgets('shows error text and stays empty with no report',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: VerificationReport(report: null)),
    ));
    expect(find.text('Verification'), findsNothing);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: VerificationReport(report: {'error': 'sidecar offline'}),
      ),
    ));
    expect(find.text('sidecar offline'), findsOneWidget);
  });

  test('testsOf extracts the test list safely', () {
    expect(VerificationReport.testsOf(null), isEmpty);
    expect(VerificationReport.testsOf({}), isEmpty);
    final tests = VerificationReport.testsOf({
      'tests': [
        {'src': 'PC1', 'dst': 'R1'},
      ],
    });
    expect(tests, hasLength(1));
    expect(tests.first['src'], 'PC1');
  });
}
