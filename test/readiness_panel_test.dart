import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/widgets/readiness_panel.dart';

void main() {
  testWidgets('the readiness panel explains optional checks and runs actions', (
    tester,
  ) async {
    var started = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadinessPanel(
            items: [
              ReadinessItem(
                label: 'Local engine',
                detail: 'No engine; offline planning still works.',
                state: ReadinessState.blocked,
                actionLabel: 'Start',
                onAction: () => started++,
              ),
              const ReadinessItem(
                label: 'Packet Tracer',
                detail: 'Not detected; offline .pkt building still works.',
                state: ReadinessState.optional,
              ),
            ],
            onDismiss: () => dismissed++,
          ),
        ),
      ),
    );

    // Collapsed by default: one status line per check is visible, the detail
    // rows (and their actions) are behind the Details toggle.
    expect(find.text('First-run readiness'), findsOneWidget);
    expect(find.text('Local engine'), findsOneWidget);
    expect(find.text('Packet Tracer'), findsOneWidget);
    expect(find.text('Start'), findsNothing);

    await tester.tap(find.text('First-run readiness'));
    await tester.pumpAndSettle();

    expect(find.text('Local engine'), findsWidgets);
    expect(find.text('Start'), findsOneWidget);

    await tester.tap(find.text('Start'));
    expect(started, 1);

    await tester.tap(find.byTooltip('Hide the setup checklist'));
    expect(dismissed, 1);
  });

  testWidgets('the details toggle collapses and re-expands the rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadinessPanel(
            items: const [
              ReadinessItem(
                label: 'Local engine',
                detail: 'Running.',
                state: ReadinessState.ready,
              ),
            ],
            onDismiss: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('First-run readiness'));
    await tester.pumpAndSettle();
    expect(find.text('Running.'), findsOneWidget);

    await tester.tap(find.text('First-run readiness'));
    await tester.pumpAndSettle();
    expect(find.text('Running.'), findsNothing);
  });
}
