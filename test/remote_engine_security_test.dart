import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/autopilot_service.dart';
import 'package:net_builder/services/engine_configuration_sync.dart';
import 'package:net_builder/services/settings_service.dart';

/// The engine API is unauthenticated. A remote address must never receive the
/// provider key, even if the user typed one into Settings or used `/pc`.
void main() {
  test(
    'EngineConfigurationSync refuses a remote engine before any request',
    () async {
      final settings = SettingsService();
      await settings.setEngineBase('http://192.168.1.20:5005');
      var requests = 0;
      final engine = AutopilotService(
        base: settings.engineBase,
        c: MockClient((request) async {
          requests++;
          return http.Response('{"ok":true}', 200);
        }),
      );

      await expectLater(
        EngineConfigurationSync.push(settings, engine),
        throwsA(isA<RemoteEngineUnsupported>()),
      );
      expect(requests, 0, reason: 'the key must not leave the machine');
    },
  );

  test(
    'pushLlmConfig refuses a remote engine even when called directly',
    () async {
      var requests = 0;
      final engine = AutopilotService(
        base: 'http://10.0.2.2:5005',
        c: MockClient((request) async {
          requests++;
          return http.Response('{"ok":true}', 200);
        }),
      );

      await expectLater(
        engine.pushLlmConfig(
          apiKey: 'sk-live-abcdefgh12345678',
          model: '',
          enabled: false,
        ),
        throwsA(isA<StateError>()),
      );
      expect(requests, 0);
    },
  );
}
