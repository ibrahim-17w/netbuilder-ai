import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/screens/memory_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/misparse_ledger.dart';
import 'package:net_builder/services/phrasing_memory_service.dart';
import 'package:net_builder/theme/app_kit.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The misparse ledger's half of the Memory screen: the rate in the health
/// strip (corrections per parsed turn, from the ledger rather than the
/// sidecar) and the review above the phrasings, where a proposed correction
/// is taught into the live index or dismissed out of it.
///
/// Every store call runs against a real schema on an ffi database, copied
/// from the chat persistence tests: the property under test is what the
/// screen does with what the ledger wrote.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(PhrasingMemoryService.clearIndex);

  Widget screen(MemoryService memory) => MultiProvider(
        providers: [ChangeNotifierProvider<MemoryService>.value(value: memory)],
        child: const MaterialApp(home: Scaffold(body: MemoryScreen())),
      );

  /// Bounded pumping, never pumpAndSettle: the screen polls the sidecar on a
  /// three-second timer, so a settle that waits for silence would run until
  /// it timed out. Each round gives real time back too - the ffi isolate's
  /// messages do not arrive inside the test's fake async zone on their own.
  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  Future<MemoryService> freshMemory(WidgetTester tester) async {
    MemoryService? memory;
    await tester.runAsync(() async {
      // A temp file, not ":memory:": sqflite hands the same cached database
      // to a repeated in-memory path, so a second test would meet a schema
      // that already exists.
      final dir = await Directory.systemTemp.createTemp('nb-misparse');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // A leftover temp directory is not worth failing a test over.
        }
      });
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/m.db');
      await MemoryService.createSchema(db);
      memory = MemoryService(injected: db);
    });
    return memory!;
  }

  /// Tall enough that the phrasings tab's panels - and the buttons on the
  /// first proposed row - sit inside the window instead of below it.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openPhrasings(WidgetTester tester) async {
    await tester.tap(find.textContaining('Phrasings').first);
    await settle(tester);
  }

  /// The screen polls on a timer and a snackbar carries its own, and a
  /// widget test fails on any timer still pending when it ends: time runs
  /// out first, then the screen is taken down so its poll is cancelled.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Finder rate() => find.byWidgetPredicate(
        (w) => w is AppMetric && w.label == 'Misparse rate',
      );

  /// One correction the user had to make three times - the threshold at
  /// which the ledger proposes it for review.
  Future<void> seedProposed(MemoryService memory) async {
    await memory.noteParsedTurn();
    for (var i = 0; i < MisparseLedger.promoteAfter; i++) {
      await memory.recordMisparse(
        original: 'make me a lab for fifty pcs',
        understood: '40 PCs, 2 switches, 2 routers',
        corrected: '50 PCs, 2 switches, 2 routers',
        slot: 'count:pc',
        source: 'tap',
      );
    }
  }

  testWidgets('the misparse rate reads n/a until a turn has been parsed',
      (tester) async {
    tall(tester);
    final memory = await freshMemory(tester);
    await tester.pumpWidget(screen(memory));
    await settle(tester);

    expect(rate(), findsOneWidget);
    expect(
      find.descendant(of: rate(), matching: find.text('n/a')),
      findsOneWidget,
      reason: 'nothing to divide by yet, so the rate says so instead of 0%',
    );
    expect(
      find.descendant(
        of: rate(),
        matching: find.textContaining('Nothing measured'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('the rate is corrections per parsed turn, to one decimal',
      (tester) async {
    tall(tester);
    final memory = await freshMemory(tester);
    // Eight turns parsed, one correction made: 12.5%, counted rather than
    // guessed - the denominator is what makes "improving" measurable.
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await memory.noteParsedTurn();
      }
      await memory.recordMisparse(
        original: 'ten pcs and two switches',
        understood: '8 PCs, 2 switches',
        corrected: '10 PCs, 2 switches',
        slot: 'count:pc',
        source: 'tap',
      );
    });
    await tester.pumpWidget(screen(memory));
    await settle(tester);

    expect(rate(), findsOneWidget);
    expect(
      find.descendant(of: rate(), matching: find.text('12.5%')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('nothing to review says so instead of showing an empty box',
      (tester) async {
    tall(tester);
    final memory = await freshMemory(tester);
    await tester.pumpWidget(screen(memory));
    await settle(tester);
    await openPhrasings(tester);

    expect(find.textContaining('No corrections yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Teach'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a proposed correction shows what was said, understood and '
      'meant, and offers both decisions', (tester) async {
    tall(tester);
    final memory = await freshMemory(tester);
    await tester.runAsync(() => seedProposed(memory));
    await tester.pumpWidget(screen(memory));
    await settle(tester);
    await openPhrasings(tester);

    expect(find.text('make me a lab for fifty pcs'), findsOneWidget);
    expect(
      find.textContaining('40 PCs, 2 switches, 2 routers'),
      findsWidgets,
      reason: 'what the app made of the words is part of the decision',
    );
    expect(
      find.textContaining('50 PCs, 2 switches, 2 routers'),
      findsWidgets,
      reason: 'what the user meant is the other half of it',
    );
    expect(find.text('3x'), findsOneWidget, reason: 'how often it happened');
    expect(find.text('tap'), findsOneWidget, reason: 'how it arrived');
    expect(find.widgetWithText(FilledButton, 'Teach'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Dismiss'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('teaching a correction empties the review and lists the '
      'phrasing', (tester) async {
    tall(tester);
    final memory = await freshMemory(tester);
    await tester.runAsync(() => seedProposed(memory));
    await tester.pumpWidget(screen(memory));
    await settle(tester);
    await openPhrasings(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Teach'));
    await settle(tester);

    expect(
      find.widgetWithText(FilledButton, 'Teach'),
      findsNothing,
      reason: 'a taught row leaves the review list',
    );
    final phrasings = (await tester.runAsync(() => memory.allPhrasings()))!;
    expect(phrasings, hasLength(1),
        reason: 'the lesson must be listable, not only marked');
    expect(phrasings.first['rewrite'], '50 PCs, 2 switches, 2 routers');
    final ledger = (await tester.runAsync(() => memory.misparseLedger()))!;
    expect(ledger.single.status, 'taught');
    await unmount(tester);
  });

  testWidgets('dismissing a correction keeps it out of the phrasings',
      (tester) async {
    tall(tester);
    final memory = await freshMemory(tester);
    await tester.runAsync(() => seedProposed(memory));
    await tester.pumpWidget(screen(memory));
    await settle(tester);
    await openPhrasings(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
    await settle(tester);

    expect(find.widgetWithText(FilledButton, 'Teach'), findsNothing);
    final phrasings = (await tester.runAsync(() => memory.allPhrasings()))!;
    expect(phrasings, isEmpty,
        reason: 'a rejected guess must never reach the replay index');
    final ledger = (await tester.runAsync(() => memory.misparseLedger()))!;
    expect(ledger.single.status, 'dismissed',
        reason: 'it stays in the ledger as evidence for the rate');
    expect(find.textContaining('Reviewed (1)'), findsOneWidget);
    await unmount(tester);
  });
}
