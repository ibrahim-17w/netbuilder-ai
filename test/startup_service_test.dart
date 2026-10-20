import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/startup_service.dart';
import 'package:net_builder/widgets/startup_banner.dart';
import 'package:flutter/material.dart';

void main() {
  test('startup loads every subsystem in parallel and becomes ready', () async {
    final startup = StartupCoordinator(
      timeout: const Duration(milliseconds: 200),
    );
    final started = <String>[];

    await startup.start(
      settings: () async {
        started.add('settings');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      memory: () async {
        started.add('memory');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      history: () async {
        started.add('history');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      version: () async {
        started.add('version');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
    );

    expect(started, containsAll(['settings', 'memory', 'history', 'version']));
    expect(startup.value.isReady, isTrue);
    expect(startup.value.isDegraded, isFalse);
    expect(startup.value.isLoading, isFalse);
    for (final status in startup.value.statuses) {
      expect(status.isReady, isTrue, reason: status.id);
      expect(status.elapsedMs, greaterThanOrEqualTo(0));
    }
  });

  test('one timeout does not hold the other subsystems hostage', () async {
    final startup = StartupCoordinator(
      timeout: const Duration(milliseconds: 30),
    );
    final never = Completer<void>();

    await startup.start(
      settings: () async {},
      memory: () => never.future,
      history: () async {},
      version: () async {},
    );

    expect(startup.value.statusOf('settings')!.isReady, isTrue);
    expect(startup.value.statusOf('history')!.isReady, isTrue);
    expect(startup.value.statusOf('version')!.isReady, isTrue);
    expect(startup.value.statusOf('memory')!.isFailed, isTrue);
    expect(startup.value.isDegraded, isTrue);
    expect(startup.value.statusOf('memory')!.detail, contains('Timed out'));
  });

  test('failure detail is redacted before it reaches the UI', () async {
    final startup = StartupCoordinator(
      timeout: const Duration(milliseconds: 200),
    );

    await startup.start(
      settings: () async {},
      memory: () async {
        throw StateError('network failed with token=supersecret123');
      },
      history: () async {},
      version: () async {},
    );

    final detail = startup.value.statusOf('memory')!.detail;
    expect(detail, contains('Using safe defaults'));
    expect(detail, isNot(contains('supersecret123')));
    expect(detail, contains('<redacted>'));
  });

  testWidgets('slow startup shows readiness and then disappears', (
    tester,
  ) async {
    final startup = StartupCoordinator(
      timeout: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StartupBanner(startup: startup)),
      ),
    );

    // Fast startup stays silent; the strip only appears once a person has
    // waited long enough to wonder what is happening.
    expect(find.textContaining('Starting'), findsNothing);
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.textContaining('Starting'), findsOneWidget);

    await startup.start(
      settings: () async {},
      memory: () async {},
      history: () async {},
      version: () async {},
    );
    await tester.pump();
    expect(find.textContaining('Starting'), findsNothing);
  });

  testWidgets('a failed subsystem stays visible with details', (tester) async {
    final startup = StartupCoordinator(
      timeout: const Duration(milliseconds: 200),
    );
    var details = 0;
    await startup.start(
      settings: () async {},
      memory: () async {
        throw StateError('disk is unavailable');
      },
      history: () async {},
      version: () async {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StartupBanner(startup: startup, onDetails: () => details++),
        ),
      ),
    );

    expect(find.textContaining('Reduced startup: Memory'), findsOneWidget);
    await tester.tap(find.text('Details'));
    expect(details, 1);
  });
}
