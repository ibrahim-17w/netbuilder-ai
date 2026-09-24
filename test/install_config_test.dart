import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fresh install must work without anyone typing a path. The installer
/// records the folders it created; the app has to adopt them.
class _MemoryStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

Future<String> _writeInstallJson(Map<String, dynamic> body) async {
  final root = await Directory.systemTemp.createTemp('nb-install-cfg');
  final config = Directory('${root.path}${Platform.pathSeparator}config')
    ..createSync();
  final file = File(
    '${config.path}${Platform.pathSeparator}install.json',
  )..writeAsStringSync(jsonEncode(body));
  return file.path;
}

void main() {
  test('a fresh install adopts the folders the installer created', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final output = 'C:${Platform.pathSeparator}Apps${Platform.pathSeparator}'
        'NetBuilderAI${Platform.pathSeparator}output';
    final path = await _writeInstallJson({
      'schemaVersion': 1,
      'outputDir': output,
      'engineBase': 'http://127.0.0.1:5005',
    });

    final settings = SettingsService(
      secure: _MemoryStorage(),
      installConfigPath: path,
    );
    await settings.load();

    expect(settings.installedWithSetup, isTrue);
    expect(settings.outputDir, output,
        reason: 'the app must not need the user to choose a folder');
    expect(settings.installInfo['schemaVersion'], 1);
  });

  test('a folder the user chose is never overwritten by the installer',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'output_dir': 'C:${Platform.pathSeparator}mine',
    });
    final path = await _writeInstallJson({
      'outputDir': 'C:${Platform.pathSeparator}Apps${Platform.pathSeparator}'
          'NetBuilderAI${Platform.pathSeparator}output',
    });

    final settings = SettingsService(
      secure: _MemoryStorage(),
      installConfigPath: path,
    );
    await settings.load();

    expect(settings.outputDir, 'C:${Platform.pathSeparator}mine');
  });

  test('no install record is fine: the app keeps its own defaults', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService(
      secure: _MemoryStorage(),
      installConfigPath: 'C:${Platform.pathSeparator}nope'
          '${Platform.pathSeparator}install.json',
    );
    await settings.load();

    expect(settings.installedWithSetup, isFalse);
    expect(settings.outputDir, isEmpty);
    expect(settings.engineBase, SettingsService.defaultEngineBase(),
        reason: 'the platform-aware default still applies');
  });

  test('an unreadable install record does not break startup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final root = await Directory.systemTemp.createTemp('nb-install-bad');
    final config = Directory('${root.path}${Platform.pathSeparator}config')
      ..createSync();
    final file = File('${config.path}${Platform.pathSeparator}install.json')
      ..writeAsStringSync('{ not json');

    final settings = SettingsService(
      secure: _MemoryStorage(),
      installConfigPath: file.path,
    );
    await settings.load();

    expect(settings.installedWithSetup, isFalse);
    expect(settings.loaded, isTrue);
  });
}
