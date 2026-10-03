import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/screens/engine_screen.dart';
import 'package:net_builder/services/autopilot_service.dart';
import 'package:net_builder/services/engine_status.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/services/sidecar_supervisor.dart';

/// The phone is the platform this app is least able to test on: it has no
/// sidecar, no Python and no Packet Tracer. These tests put the app on a phone
/// (`debugDefaultTargetPlatformOverride`) and check that it says the true
/// thing instead of hunting for an interpreter that cannot exist.
/// Run [body] as a phone or as a desktop. The switch is put back before the
/// body returns, so no other test inherits it.
Future<void> asMobile(bool mobile, Future<void> Function() body) async {
  SettingsService.mobileOverrideForTests = mobile;
  try {
    await body();
  } finally {
    SettingsService.mobileOverrideForTests = null;
  }
}

void main() {
  tearDown(() => SettingsService.mobileOverrideForTests = null);

  group('on a phone', () {
    setUp(() => SettingsService.mobileOverrideForTests = true);

    test('the app knows it cannot host the engine', () {
      expect(SettingsService.isMobile, isTrue);
      expect(SettingsService.isAndroid, isTrue);
      expect(SettingsService.canHostEngine, isFalse);
      expect(SidecarSupervisor.canRunLocally, isFalse);
    });

    test('it never tries to start a sidecar, and says where the engine is', () async {
      final result = await SidecarSupervisor.ensureStarted(force: true);
      expect(result.ok, isFalse);
      expect(result.method, 'phone');
      expect(result.message, contains('PC'));
      expect(result.message, contains('5005'));
      expect(SidecarSupervisor.searchRoots(), isEmpty,
          reason: 'there is nothing to find on a phone');
      expect(SidecarSupervisor.weStartedIt, isFalse);
    });

    test('engine status refuses to launch and explains why', () async {
      var launched = 0;
      final status = EngineStatus(
        healthProbe: (base, timeout) async => <String, dynamic>{'ok': false},
        launcher: () async {
          launched++;
          return const SidecarLaunchResult(ok: true, message: 'started');
        },
      );

      expect(status.canStartLocally, isFalse);
      expect(await status.ensure(force: true), isFalse);
      expect(launched, 0,
          reason: 'a phone must not spawn a process that cannot exist');
      expect(status.detail, contains('PC'));
      expect(status.summary, contains('PC'));
    });

    test('a .pkt job on a phone says where the engine is', () {
      expect(AutopilotService.startHint, contains('PC'));
      expect(
        AutopilotService.startHint,
        isNot(contains('python.org')),
        reason: 'Python cannot be installed on a phone, so that advice is noise',
      );
      expect(AutopilotService.desktopStartHint, contains('python.org'),
          reason: 'on a desktop the Python steps are exactly what is needed');
    });

    test('the default engine address is the host, not the phone', () {
      expect(SettingsService.defaultEngineBase(), 'http://10.0.2.2:5005');
      expect(SettingsService.defaultGns3Endpoint(), 'http://10.0.2.2:3080');
      expect(
        SettingsService.engineHint('http://127.0.0.1:5005'),
        contains('PC'),
        reason: 'loopback on a phone is the phone itself',
      );
      expect(
        SettingsService.engineHint('http://10.0.2.2:5005'),
        contains('emulator'),
      );
    });

    test('the diagnostics report says the engine is elsewhere', () async {
      final status = EngineStatus(
        healthProbe: (base, timeout) async => <String, dynamic>{'ok': false},
      );
      final report = await status.diagnose();
      expect(report, contains('can host the engine here: false'));
      expect(report, contains('platform:'));
    });

    testWidgets('the engine screen tells a phone what to do instead',
        (tester) async {
      await asMobile(true, () async {
        await tester.pumpWidget(const MaterialApp(home: EngineScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Start the engine'), findsNothing);
        expect(find.text('Restart'), findsNothing);
        expect(find.text('Stop'), findsNothing);
        expect(find.textContaining('The engine runs on a PC'), findsOneWidget);
        expect(find.textContaining('10.0.2.2'), findsWidgets,
            reason: 'the emulator host is the one address that always works');
      });
    });

    testWidgets('the chat offers the address, never a start button',
        (tester) async {
      await asMobile(true, () async {
        await tester.pumpWidget(const NetBuilderApp());
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }

        expect(find.textContaining('No .pkt engine at'), findsOneWidget);
        expect(find.textContaining('On a phone the engine runs on your PC'),
            findsOneWidget);
        expect(find.text('Set address'), findsOneWidget);
        expect(find.text('Start engine'), findsNothing,
            reason: 'a button that cannot work is worse than no button');
      });
    });
  });

  group('on a desktop', () {
    setUp(() => SettingsService.mobileOverrideForTests = false);

    test('the local engine is still the app\'s to start', () {
      expect(SettingsService.isMobile, isFalse);
      expect(SettingsService.canHostEngine, isTrue);
      expect(SidecarSupervisor.canRunLocally, isTrue);
      expect(SettingsService.defaultEngineBase(), 'http://127.0.0.1:5005');
    });

    testWidgets('the chat still offers to start it', (tester) async {
      await asMobile(false, () async {
        await tester.pumpWidget(const NetBuilderApp());
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(find.text('Start engine'), findsOneWidget);
      });
    });
  });
}
