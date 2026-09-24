import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/network_toolkit_screen.dart';

void main() {
  Future<void> pumpToolkit(
    WidgetTester tester,
    ToolkitSection section, {
    NetworkIntent? intent,
  }) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: NetworkToolkitScreen(initialSection: section, intent: intent),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the subnet calculator answers for whatever is typed', (
    tester,
  ) async {
    await pumpToolkit(tester, ToolkitSection.subnet);

    // The section is named in the rail and in the heading.
    expect(find.text('Subnet calculator'), findsWidgets);
    // The default block.
    expect(find.text('255.255.255.0'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '10.10.10.0/30');
    await tester.pumpAndSettle();

    expect(find.text('255.255.255.252'), findsOneWidget);
    expect(find.text('0.0.0.3'), findsOneWidget);
    expect(find.text('10.10.10.1 - 10.10.10.2'), findsOneWidget);
    expect(find.textContaining('2 usable of 4 addresses'), findsWidgets);
  });

  testWidgets('an invalid network is explained rather than ignored', (
    tester,
  ) async {
    await pumpToolkit(tester, ToolkitSection.subnet);

    await tester.enterText(find.byType(TextField).first, '300.1.1.1/24');
    await tester.pumpAndSettle();

    expect(find.text('Not a valid IPv4 network'), findsOneWidget);
  });

  testWidgets('the VLSM tool allocates the biggest requirements first', (
    tester,
  ) async {
    await pumpToolkit(tester, ToolkitSection.vlsm);

    expect(find.text('VLSM and splitting'), findsWidgets);
    // The starting example: /22 split for 200, 100, 60 and 2 hosts.
    expect(find.textContaining('192.168.0.0/24'), findsOneWidget);
    expect(find.textContaining('192.168.1.128/26'), findsOneWidget);
    expect(find.textContaining('192.168.1.192/30'), findsOneWidget);
    expect(find.textContaining('All 4 sites fit'), findsOneWidget);
  });

  testWidgets('the ACL helper derives the inverse mask and an ACL line', (
    tester,
  ) async {
    await pumpToolkit(tester, ToolkitSection.acl);

    await tester.enterText(find.byType(TextField).first, '192.168.10.0/24');
    await tester.pumpAndSettle();

    expect(find.textContaining('wildcard    0.0.0.255'), findsOneWidget);
    expect(find.textContaining('mask        255.255.255.0'), findsOneWidget);
    expect(
      find.textContaining('access-list 100 permit tcp 192.168.10.0 0.0.0.255'),
      findsOneWidget,
    );
    expect(
      find.textContaining('10.168.192.in-addr.arpa'),
      findsOneWidget,
    );
  });

  testWidgets('every exporter renders the open plan', (tester) async {
    final intent = NetworkIntent.parseSimple('office', '2 routers 1 switch ospf');
    await pumpToolkit(tester, ToolkitSection.exporters, intent: intent);

    expect(find.text('Cisco IOS configuration'), findsOneWidget);
    expect(find.text('Terraform (AWS VPC)'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(Card, 'Terraform (AWS VPC)'),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();

    // The artifact opens in a dialog, ready to copy: this adapter had no
    // button anywhere in the app before the toolkit.
    expect(find.textContaining('aws_vpc'), findsWidgets);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('with no plan open the exporters say why', (tester) async {
    await pumpToolkit(tester, ToolkitSection.exporters);
    expect(find.text('No plan is open'), findsOneWidget);
  });

  testWidgets('the addressing tool reports the plan it is checking', (
    tester,
  ) async {
    final intent = NetworkIntent(
      projectName: 'dupes',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
      ],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 'f0/0', ipCidr: '192.168.1.1/24'),
        InterfaceAddr(node: 'R2', iface: 'f0/0', ipCidr: '192.168.1.1/24'),
      ],
    );
    await pumpToolkit(tester, ToolkitSection.addressing, intent: intent);

    expect(find.textContaining('Duplicate addresses: 1'), findsOneWidget);
    expect(find.textContaining('192.168.1.1 used by R1 f0/0, R2 f0/0'),
        findsOneWidget);
    expect(find.textContaining('Overlapping subnets: none'), findsOneWidget);
  });

  testWidgets('the diagnostics and local tools probe nothing until asked', (
    tester,
  ) async {
    await pumpToolkit(tester, ToolkitSection.diagnostics);
    expect(find.text('DNS lookup'), findsOneWidget);
    expect(find.text('Scan common ports'), findsOneWidget);
    expect(find.textContaining('No results yet'), findsOneWidget);

    await pumpToolkit(tester, ToolkitSection.local);
    expect(find.text('My interfaces'), findsOneWidget);
    expect(find.text('ARP table'), findsOneWidget);
    expect(find.textContaining('No results yet'), findsOneWidget);
  });
}
