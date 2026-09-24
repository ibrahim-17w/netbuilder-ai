import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/screens/home_screen.dart';

BuildRecord _rec(String name, String status, DateTime at) => BuildRecord(
  projectName: name,
  instruction: 'test instruction for $name',
  intentJson: '{"projectName":"$name"}',
  target: 'packet-tracer',
  status: status,
  createdAt: at,
);

void main() {
  testWidgets('dashboard renders counts from the records', (tester) async {
    final now = DateTime.now();
    final records = [
      _rec('a', 'verified', now),
      _rec('b', 'verified', now.subtract(const Duration(days: 2))),
      _rec('c', 'failed', now.subtract(const Duration(days: 1))),
      _rec('d', 'planned', now.subtract(const Duration(days: 30))),
    ];
    final dashboard = HistoryDashboard(items: records);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: dashboard)));
    expect(find.text('4'), findsOneWidget); // total builds
    expect(find.text('50%'), findsOneWidget); // 2 verified of 4
    expect(find.text('1'), findsOneWidget); // needs attention
    expect(find.text('3'), findsOneWidget); // last 7 days
  });

  testWidgets('empty history shows zeros', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HistoryDashboard(items: const []))),
    );
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('Builds'), findsOneWidget);
  });
}
