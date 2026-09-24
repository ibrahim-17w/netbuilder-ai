import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/app/destinations.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/capability_registry.dart';
import 'package:net_builder/widgets/action_hub.dart';

/// The hub is a function of its host, so the test supplies a host that records
/// what it was asked to do instead of moving a real app around.
class _Host {
  final calls = <String>[];
  final NetworkIntent? intent;

  _Host({this.intent});

  Widget harness() => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: ActionHubPanel(
          host: ActionContext(
            context: context,
            current: AppDestination.chat,
            intent: intent,
            go: (destination) => calls.add('go:${destination.name}'),
            push: (screen) => calls.add('push:${screen.runtimeType}'),
            openChat: ({required project, prefill = ''}) =>
                calls.add('chat:$project:$prefill'),
            openDrawer: () => calls.add('drawer'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('every capability is rendered as a labelled button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final host = _Host();
    await tester.pumpWidget(host.harness());
    await tester.pumpAndSettle();

    expect(find.text('Find a feature'), findsOneWidget);
    // The groups are the map of the app's abilities.
    expect(find.text('PLAN A NETWORK'), findsOneWidget);
    expect(find.text('NETWORK TOOLS'), findsOneWidget);
    expect(find.text('Open the network toolkit'), findsOneWidget);
    expect(find.text('Live diagnostics: DNS, ports, HTTP, ping'), findsOneWidget);

    // The list is long by design, so the later groups are reached by search
    // - which is how the hub is meant to be used anyway.
    await tester.enterText(find.byType(TextField).first, 'terraform');
    await tester.pumpAndSettle();
    expect(find.text('EXPORTS'), findsOneWidget);
    expect(find.text('Terraform (AWS VPC)'), findsOneWidget);
  });

  testWidgets('search narrows to the matching capabilities', (tester) async {
    final host = _Host();
    await tester.pumpWidget(host.harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'terraform');
    await tester.pumpAndSettle();

    expect(find.text('Terraform (AWS VPC)'), findsOneWidget);
    expect(find.text('Subnet calculator'), findsNothing);
    expect(find.textContaining('feature(s) match'), findsOneWidget);
  });

  testWidgets('a plan-dependent action is visible but disabled without a plan',
      (tester) async {
    final host = _Host();
    await tester.pumpWidget(host.harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Check the plan');
    await tester.pumpAndSettle();

    expect(find.text('Check the plan for errors'), findsOneWidget);
    expect(find.text('Open a plan first'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Check the plan for errors'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      host.calls,
      isEmpty,
      reason: 'a disabled capability must not run anything',
    );
  });

  testWidgets('tapping a navigation action moves the shell', (tester) async {
    final host = _Host();
    await tester.pumpWidget(host.harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Open the chat');
    await tester.pumpAndSettle();
    // The query is in the field as well, so tap the tile in the list itself.
    await tester.tap(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Open the chat'),
      ),
    );
    await tester.pumpAndSettle();

    expect(host.calls, ['go:chat']);
  });

  testWidgets('a chat opener hands the question to the conversation', (
    tester,
  ) async {
    final host = _Host();
    await tester.pumpWidget(host.harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'explain the plan');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Ask the assistant to explain the plan'),
      ),
    );
    await tester.pumpAndSettle();

    expect(host.calls.single, startsWith('chat:default:Explain the current plan'));
  });

  testWidgets('with a plan open, the same action becomes available', (
    tester,
  ) async {
    final host = _Host(
      intent: NetworkIntent.parseSimple('office', '2 routers 1 switch ospf'),
    );
    await tester.pumpWidget(host.harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'duplicate');
    await tester.pumpAndSettle();

    expect(find.text('Find duplicate addresses in the plan'), findsOneWidget);
    expect(find.text('Open a plan first'), findsNothing);
    expect(find.text('Plan open'), findsOneWidget);
  });
}
