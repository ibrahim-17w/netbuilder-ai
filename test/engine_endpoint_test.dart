import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/autopilot_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

/// The configured engine address is authoritative.
///
/// Every request a client makes has to go to the address the user set. The
/// failure this guards against is quiet and total: a screen that builds its
/// own client defaults to loopback, so changing the address in Settings
/// appears to do nothing on that screen - and the error text then names an
/// address the user never configured.
void main() {
  /// Records the URL of every request, so "which engine did this talk to" is
  /// a fact rather than an inference.
  final asked = <String>[];

  http.Client recorder() => MockClient((request) async {
        asked.add(request.url.toString());
        return http.Response(
          jsonEncode({
            'ok': true,
            'version': '1.0',
            'rpa': false,
            'ocr': false,
          }),
          200,
        );
      });

  setUp(asked.clear);

  test('the address is resolved per request, not captured at construction',
      () async {
    // Stands in for SettingsService.engineBase: it changes between calls,
    // which is exactly what the user does in Settings.
    var configured = 'http://192.168.1.20:5005';
    final svc = AutopilotService(baseProvider: () => configured, c: recorder());

    expect(await svc.healthy, isTrue);
    expect(asked.single, 'http://192.168.1.20:5005/health');

    // Change the setting. No new client, no rebuild: the next request must
    // already go to the new machine.
    configured = 'http://10.0.2.2:5005';
    expect(await svc.healthy, isTrue);
    expect(asked.last, 'http://10.0.2.2:5005/health');

    // A POST resolves it the same way, so a start cannot slip back to a
    // stale address while a GET looks fine.
    await svc.dryRun({'project': 'x', 'steps': <dynamic>[]});
    expect(asked.last, 'http://10.0.2.2:5005/dry_run');
  });

  test('an explicit base wins, for the drawer testing an unsaved address',
      () async {
    final svc = AutopilotService(
      base: '  http://10.1.2.3:5005  ',
      baseProvider: () => 'http://192.168.1.20:5005',
      c: recorder(),
    );

    expect(svc.base, 'http://10.1.2.3:5005');
    expect(await svc.healthy, isTrue);
    expect(asked.single, 'http://10.1.2.3:5005/health');
  });

  test('loopback is only the last resort, never a silent default', () {
    // A bare client with nothing to resolve from still has to answer with
    // something; it is a fallback, not the app's decision.
    expect(AutopilotService().base, AutopilotService.loopbackBase);

    // An empty resolver (settings not loaded yet) is the same case, and the
    // same fallback.
    expect(
      AutopilotService(baseProvider: () => '   ').base,
      AutopilotService.loopbackBase,
    );

    // A resolver that throws must not take the screen down with it.
    final broken = AutopilotService(
      baseProvider: () => throw StateError('settings are gone'),
    );
    expect(broken.base, AutopilotService.loopbackBase);
  });

  test('the failure text names the address that did not answer', () async {
    // What the real client raises when nothing is listening: a
    // ClientException carrying the transport error.
    final svc = AutopilotService(
      baseProvider: () => 'http://192.168.1.20:5005',
      c: MockClient(
        (_) async => throw http.ClientException(
          'Connection refused',
          Uri.parse('http://192.168.1.20:5005/status'),
        ),
      ),
    );

    expect(await svc.healthy, isFalse);
    expect(
      svc.hint,
      startsWith('The engine at http://192.168.1.20:5005 is not answering'),
      reason: 'the address that did not answer is the one the user set, and '
          'it has to be the one named',
    );
    expect(
      svc.hint,
      isNot(contains('python.org')),
      reason: 'a remote engine is not started by installing Python here',
    );

    // The thrown message carries the same address, so a screen that shows the
    // error verbatim names the right machine too.
    try {
      await svc.statusDetails();
      fail('an unreachable engine must throw');
    } catch (e) {
      expect(e.toString(), contains('192.168.1.20:5005'));
    }
  });

  test('a loopback failure keeps the local start steps', () async {
    final svc = AutopilotService(
      baseProvider: () => 'http://127.0.0.1:5005',
      c: MockClient(
        (_) async => throw http.ClientException('Connection refused'),
      ),
    );
    expect(await svc.healthy, isFalse);
    expect(svc.hint, contains('127.0.0.1:5005'));
    expect(svc.hint, contains('python.org'));
  });

  test('the hint follows the address as it changes', () {
    var configured = 'http://10.0.2.2:5005';
    final svc = AutopilotService(baseProvider: () => configured);
    expect(svc.hint, contains('10.0.2.2:5005'));

    configured = 'http://192.168.1.20:5005';
    expect(svc.hint, contains('192.168.1.20:5005'));
  });

  testWidgets('a tree without the provider still reads the settings',
      (tester) async {
    final settings = SettingsService();
    await settings.setEngineBase('192.168.9.9');

    late AutopilotService resolved;
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = AutopilotService.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(resolved.base, 'http://192.168.9.9:5005');
  });

  testWidgets('the app-scoped instance is the one the tree provides',
      (tester) async {
    final settings = SettingsService();
    await settings.setEngineBase('192.168.1.20:5005');
    final shared = AutopilotService(baseProvider: () => settings.engineBase);

    late AutopilotService resolved;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          Provider<AutopilotService>.value(value: shared),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = AutopilotService.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    // The SAME instance, not an equivalent one: two clients means two
    // addresses the moment the setting changes.
    expect(identical(resolved, shared), isTrue);
    expect(resolved.base, 'http://192.168.1.20:5005');

    await settings.setEngineBase('10.0.2.2');
    expect(resolved.base, 'http://10.0.2.2:5005');
  });
}
