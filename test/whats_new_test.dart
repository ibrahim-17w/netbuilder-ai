import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/widgets/whats_new.dart';

/// The tour and the changelog card are both "show this once" surfaces, so
/// these tests pin the gating: they must be visible to a fresh install and
/// gone the moment the user has seen them.
void main() {
  test('the changelog has entries, newest first', () {
    expect(kChangelogEntries, isNotEmpty);
    // Newest first is the contract the card relies on: `first` is the
    // release the card announces.
    final versions = kChangelogEntries.map((e) => e.version).toList();
    final sorted = [...versions]..sort();
    expect(versions, sorted.reversed);
    for (final entry in kChangelogEntries) {
      expect(entry.changes, isNotEmpty);
      expect(entry.date, isNotEmpty);
    }
  });

  testWidgets('the changelog card appears until its version is seen',
      (tester) async {
    final settings = SettingsService();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChangelogCard(settings: settings))),
    );

    expect(find.textContaining('New in ${kChangelogEntries.first.version}'),
        findsOneWidget);
    expect(find.textContaining(kChangelogEntries.first.changes.first),
        findsOneWidget);

    // Dismissing it records the version and the card disappears for good.
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('the tour is shown once and then stays gone', (tester) async {
    final settings = SettingsService();
    final tour = FirstRunTour(settings: settings);

    expect(settings.tourDone, isFalse);

    // First launch: the dialog opens on the first page and offers an exit.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => tour.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Describe it. It builds it.'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(settings.tourDone, isTrue);
    expect(find.byType(Dialog), findsNothing);

    // Second launch: nothing opens, because the tour is a one-time offer.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('the tour pages advance to the last one', (tester) async {
    final settings = SettingsService();
    var finished = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => FirstRunTour(
                  settings: settings,
                  onFinish: () => finished++,
                ).show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Three 'Next' pages, then a final button that says what it does. The
    // last page must finish the tour rather than trapping the user.
    for (var i = 0; i < 3; i++) {
      expect(find.text('Next'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Show me around'), findsOneWidget);
    await tester.tap(find.text('Show me around'));
    await tester.pumpAndSettle();

    expect(settings.tourDone, isTrue);
    expect(finished, 1);
    expect(find.byType(Dialog), findsNothing);
  });
}
