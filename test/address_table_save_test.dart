import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/network_toolkit_screen.dart';

void main() {
  const plan = NetworkIntent(
    projectName: 'addresses',
    nodes: [NetNode(name: 'R1', type: 'router')],
    addressing: [
      InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '10.0.0.1/24'),
    ],
  );
  for (final fail in [false, true]) {
    testWidgets(
      'address table waits for ${fail ? 'failed' : 'successful'} persistence',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final completion = Completer<void>();
        NetworkIntent? edited;
        await tester.pumpWidget(
          MaterialApp(
            home: NetworkToolkitScreen(
              initialSection: ToolkitSection.addressing,
              intent: plan,
              onSavePlan: (p) {
                edited = p;
                return completion.future;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cell = find.text('10.0.0.1/24');
        await tester.ensureVisible(cell);
        await tester.tap(cell);
        await tester.pumpAndSettle();
        final field = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first;
        await tester.enterText(field, '10.0.0.9/24');
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(edited!.addressing.single.ipCidr, '10.0.0.9/24');
        expect(find.textContaining('updated and saved'), findsNothing);
        if (fail) {
          completion.completeError(StateError('disk failure'));
        } else {
          completion.complete();
        }
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            fail ? 'could not be saved' : 'updated and saved',
          ),
          findsOneWidget,
        );
        expect(find.text(fail ? '10.0.0.1/24' : '10.0.0.9/24'), findsWidgets);
      },
    );
  }
}
