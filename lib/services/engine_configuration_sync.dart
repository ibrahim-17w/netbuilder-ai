import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'autopilot_service.dart';
import 'settings_service.dart';
import 'engine_status.dart';

/// Thrown when a caller tries to push provider settings to a non-loopback
/// engine. The message is deliberately explicit: this is a security refusal,
/// not a temporary connection failure.
class RemoteEngineUnsupported implements Exception {
  final String base;
  const RemoteEngineUnsupported(this.base);

  @override
  String toString() =>
      'Remote engines are unsupported ($base). Provider keys stay on this '
      'device; run the engine on this PC.';
}

/// One settings path for startup, live changes, and execution entry points.
class EngineConfigurationSync extends ChangeNotifier {
  EngineConfigurationSync(this.settings, this.engine, this.status) {
    settings.addListener(_changed);
    status.addListener(_engineChanged);
    _changed();
  }
  final SettingsService settings;
  final AutopilotService engine;
  final EngineStatus status;
  static int _revision = DateTime.now().microsecondsSinceEpoch;
  String error = '';
  String _lastEngine = '';
  int _request = 0;
  void _changed() {
    final request = ++_request;
    // Phone builds use the bundled Dart compiler. Sending desktop-only
    // automation settings to the default Android host alias created a false
    // "engine did not receive settings" warning on every launch.
    if (SettingsService.isMobile) {
      if (error.isNotEmpty) {
        error = '';
        notifyListeners();
      }
      return;
    }
    // Never read the keychain for an address that is not this machine. A
    // remote engine is unsupported precisely because the API is plaintext and
    // unauthenticated; refusing here means the credential is never decrypted,
    // let alone sent.
    if (!SettingsService.isLoopbackEngineBase(settings.engineBase)) {
      error =
          'Remote engines are unsupported. Provider keys stay on this device; '
          'run the engine on this PC.';
      notifyListeners();
      return;
    }
    unawaited(
      push(settings, engine)
          .then<void>((_) {
            if (request != _request) return;
            error = '';
            notifyListeners();
          })
          .catchError((Object e) {
            if (request != _request) return;
            error = e is RemoteEngineUnsupported
                ? 'Remote engines are unsupported. Provider keys stay on this '
                      'device; run the engine on this PC.'
                : 'The engine has not received your latest privacy and model '
                      'settings. Reconnect it before running a build.';
            notifyListeners();
          }),
    );
  }

  void _engineChanged() {
    if (!status.isUp) return;
    final identity = '${status.base}:${jsonEncode(status.engineIdentity)}';
    if (identity == _lastEngine && error.isEmpty) return;
    _lastEngine = identity;
    _changed();
  }

  @override
  void dispose() {
    _request++;
    settings.removeListener(_changed);
    status.removeListener(_engineChanged);
    super.dispose();
  }

  static Future<void> push(
    SettingsService settings,
    AutopilotService engine,
  ) async {
    if (!SettingsService.isLoopbackEngineBase(settings.engineBase)) {
      throw RemoteEngineUnsupported(settings.engineBase);
    }
    final revision = ++_revision;
    final config = settings.providerConfig;
    final disabled = settings.privateMode || !settings.llmFix;
    // A privacy kill switch must not wait for a keychain read.
    final key = disabled
        ? ''
        : (settings.usesOpenAi
              ? await settings.getOpenAiKey() ?? ''
              : await settings.getApiKey() ?? '');
    if (revision != _revision) return;
    await engine.pushLlmConfig(
      apiKey: key,
      model: config.model,
      provider: config.kind.name,
      baseUrl: config.effectiveBaseUrl(),
      extraHeaders: disabled
          ? const {}
          : {
              ...config.extraHeaders,
              if (config.organization.isNotEmpty)
                'OpenAI-Organization': config.organization,
            },
      enabled: !disabled,
      autoLearn: settings.autoLearn,
      autoSuggest: settings.autoLearn && settings.autoSuggest,
      autoTeach: settings.autoLearn && settings.autoTeach,
      configRevision: revision,
    );
  }
}
