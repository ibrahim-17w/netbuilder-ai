import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/widgets/packet_tracer_catalog.dart';
import 'package:net_builder/widgets/packet_tracer_connection_editor.dart';

void main() {
  testWidgets(
    'catalog searches exact models and returns the selected hardware',
    (tester) async {
      PtDeviceChoice? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selected = await PacketTracerCatalogSheet.show(
                    context,
                    selectDevice: true,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2960-24TT');
      await tester.pumpAndSettle();
      await tester.tap(find.text('2960-24TT').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Live verification not recorded'),
        findsOneWidget,
      );
      await tester.tap(find.text('Use device'));
      await tester.pumpAndSettle();
      expect(selected?.device.model, '2960-24TT');
      expect(selected?.variant.ports, isNotEmpty);
    },
  );
  testWidgets(
    'catalog makes all cable names available without a desktop server',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PacketTracerCatalogSheet())),
      );
      await tester.tap(find.text('Cables'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'console');
      await tester.pumpAndSettle();
      expect(find.text('Console / rollover'), findsOneWidget);
      expect(find.textContaining('Needs desktop'), findsOneWidget);
    },
  );
  testWidgets(
    'connection editor excludes occupied ports and preserves cable choice',
    (tester) async {
      NetLink? saved;
      const intent = NetworkIntent(
        projectName: 'ports',
        nodes: [
          NetNode(name: 'R1', type: 'router', model: '2911'),
          NetNode(name: 'SW1', type: 'switch', model: '2960-24TT'),
          NetNode(name: 'PC1', type: 'pc', model: 'PC-PT'),
        ],
        links: [
          NetLink(
            a: 'PC1',
            aIf: 'FastEthernet0',
            b: 'SW1',
            bIf: 'FastEthernet0/1',
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  saved = await PacketTracerConnectionEditor.show(
                    context,
                    intent: intent,
                    a: 'R1',
                    b: 'SW1',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.last.controller!.text, isNot('FastEthernet0/1'));
      await tester.tap(find.text('Add connection'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.exactPorts, isTrue);
      expect(saved!.cable, 'copper');
      expect(saved!.bIf, isNot('FastEthernet0/1'));
    },
  );
  testWidgets(
    'phone editor explains incompatible hardware without overflowing',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const intent = NetworkIntent(
        projectName: 'fiber',
        nodes: [
          NetNode(name: 'A', type: 'pc', model: 'PC-PT'),
          NetNode(name: 'B', type: 'pc', model: 'PC-PT'),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PacketTracerConnectionEditor(intent: intent, a: 'A', b: 'B'),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Fiber multimode').last,
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Fiber multimode').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('0 free compatible ports'), findsOneWidget);
      await tester.tap(find.text('Add connection'));
      await tester.pumpAndSettle();
      expect(find.text('Select a port at each end.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unknown existing cable requires an explicit replacement', (
    tester,
  ) async {
    const link = NetLink(
      a: 'A',
      aIf: 'GigabitEthernet0/0',
      b: 'B',
      bIf: 'GigabitEthernet0/1',
      cable: 'magic cable',
      exactPorts: true,
    );
    const intent = NetworkIntent(
      projectName: 'unknown',
      nodes: [
        NetNode(name: 'A', type: 'router', model: '2911'),
        NetNode(name: 'B', type: 'switch', model: '2960-24TT'),
      ],
      links: [link],
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PacketTracerConnectionEditor(
            intent: intent,
            a: 'A',
            b: 'B',
            existing: link,
          ),
        ),
      ),
    );
    expect(find.text('Unknown: magic cable'), findsOneWidget);
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();
    expect(
      find.text('Select a known cable type before saving.'),
      findsOneWidget,
    );
  });
}
