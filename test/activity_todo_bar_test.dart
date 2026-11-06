import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/widgets/chat_activity.dart';

/// The agent-style to-do bar above the composer: collapsed it is one line
/// with a chevron and a done/total count; expanded it is the checklist.
/// Geometry is asserted, not assumed - the composer must sit BELOW the bar,
/// never under it, and a long list scrolls inside the bar instead of
/// overflowing.
void main() {
  Widget host(List<Widget> children) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      body: Column(
        children: [
          const Expanded(child: SizedBox()),
          ...children,
        ],
      ),
    ),
  );

  final steps = const [
    ActivityEntry('Reading the engine health', status: ActivityStatus.ok),
    ActivityEntry('Placing 6 devices', status: ActivityStatus.ok),
    ActivityEntry('Cabling 5 links', status: ActivityStatus.running),
  ];

  group('the collapsed bar', () {
    testWidgets('is one line with count and chevron, no overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: steps,
            expanded: false,
            working: true,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(height: 40),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('2/3'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      // The step list is absent while collapsed.
      expect(find.text('Placing 6 devices'), findsNothing);
    });

    testWidgets('shows the running step next to the header', (tester) async {
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: steps,
            expanded: false,
            working: true,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(height: 40),
        ]),
      );
      expect(
        find.textContaining('Working through the network'),
        findsOneWidget,
      );
      expect(find.textContaining('Cabling 5 links'), findsOneWidget);
    });

    testWidgets('a finished turn reads To-do with a check', (tester) async {
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: [
              for (final s in steps) s.copyWith(status: ActivityStatus.ok),
            ],
            expanded: false,
            working: false,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(height: 40),
        ]),
      );
      expect(find.text('To-do'), findsOneWidget);
      expect(find.text('3/3'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('the expanded checklist', () {
    testWidgets('every step shows with its state icon', (tester) async {
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: steps,
            expanded: true,
            working: true,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(height: 40),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Reading the engine health'), findsOneWidget);
      expect(find.text('Placing 6 devices'), findsOneWidget);
      expect(find.text('Cabling 5 links'), findsOneWidget);
      // Done steps are struck through; the running one is not.
      final doneText = tester.widget<Text>(
        find.text('Reading the engine health'),
      );
      expect(doneText.style?.decoration, TextDecoration.lineThrough);
      final runText = tester.widget<Text>(find.text('Cabling 5 links'));
      expect(
        runText.style?.decoration,
        isNot(TextDecoration.lineThrough),
        reason: 'the running step is not struck through',
      );
    });

    testWidgets('a long list scrolls inside the bar, never overflowing', (
      tester,
    ) async {
      final many = [
        for (var i = 0; i < 30; i++)
          ActivityEntry(
            'Step $i of a very long run that wraps a little',
            status: ActivityStatus.ok,
          ),
      ];
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: many,
            expanded: true,
            working: false,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(height: 40),
        ]),
      );
      // No overflow exception is the assertion: 30 rows cannot fit under
      // the bar's 200-px ceiling, so they must scroll inside it.
      expect(tester.takeException(), isNull);
      expect(
        find.text('Step 0 of a very long run that wraps a little'),
        findsOneWidget,
      );
      // SingleChildScrollView builds every row; the proof of containment
      // is no overflow exception plus the rows actually scrolling.
      await tester.scrollUntilVisible(
        find.text('Step 29 of a very long run that wraps a little'),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
        find.text('Step 29 of a very long run that wraps a little'),
        findsOneWidget,
      );
    });
  });

  group('geometry against the composer', () {
    testWidgets('the bar sits above the composer with no overlap', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: steps,
            expanded: true,
            working: true,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(
            height: 60,
            child: TextField(decoration: InputDecoration(labelText: 'Message')),
          ),
        ]),
      );
      expect(tester.takeException(), isNull);
      final barBox = tester.renderObject<RenderBox>(
        find.byType(ActivityTodoBar),
      );
      final composerBox = tester.renderObject<RenderBox>(
        find.byType(TextField),
      );
      final barBottom = barBox.localToGlobal(Offset(0, barBox.size.height)).dy;
      final composerTop = composerBox.localToGlobal(Offset.zero).dy;
      expect(
        barBottom,
        lessThanOrEqualTo(composerTop),
        reason: 'the to-do bar must end at or above the composer top',
      );
    });

    testWidgets('an empty entries list renders nothing at all', (tester) async {
      await tester.pumpWidget(
        host([
          ActivityTodoBar(
            entries: const [],
            expanded: true,
            working: true,
            onToggle: () {},
            onDismiss: () {},
          ),
          const SizedBox(height: 40),
        ]),
      );
      // The configuration element stays in the tree; build returns
      // SizedBox.shrink, so nothing VISIBLE renders.
      expect(find.text('0/0'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.textContaining('Working'), findsNothing);
    });
  });

  test('the entry contract the bar reads: states carry through copyWith', () {
    const entry = ActivityEntry('x', status: ActivityStatus.ok);
    expect(
      entry.copyWith(status: ActivityStatus.failed).status,
      ActivityStatus.failed,
    );
    expect(entry.copyWith(detail: 'e').detail, 'e');
    expect(entry.detail, '');
  });
}
