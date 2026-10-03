import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An in-memory stand-in for the platform key store, with switches for the
/// two ways it fails in the field: a value that cannot be decrypted, and a
/// write that appears to succeed but does not persist.
class _FakeStorage extends FlutterSecureStorage {
  _FakeStorage({
    this.throwOnRead = false,
    this.dropWrites = false,
    this.throwOnKeys = const {},
    this.dropWriteKeys = const {},
    this.readFailureText = 'javax.crypto.BadPaddingException: could not decrypt',
  });

  final bool throwOnRead;
  final bool dropWrites;

  /// Only these keys fail, so one broken entry can be shown not to take the
  /// rest of the configuration with it.
  final Set<String> throwOnKeys;
  final Set<String> dropWriteKeys;
  final String readFailureText;

  final Map<String, String> values = {};
  final List<String> deleted = [];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnRead || throwOnKeys.contains(key)) {
      throw Exception(readFailureText);
    }
    return values[key];
  }

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
    if (dropWrites || dropWriteKeys.contains(key)) return;
    if (value == null) {
      values.remove(key);
      return;
    }
    values[key] = value;
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
    deleted.add(key);
    values.remove(key);
  }
}

void main() {
  test('a saved key survives the app being rebuilt from scratch', () async {
    final storage = _FakeStorage();
    final first = SettingsService(secure: storage);

    expect(await first.setApiKey('AIzaSyTESTKEY-0123456789'), isTrue);
    expect(await first.getApiKey(), 'AIzaSyTESTKEY-0123456789');
    expect(first.keyUnreadable, isFalse);

    // A brand-new service over the same device storage is what a restart
    // looks like. The key must still be there.
    final afterRestart = SettingsService(secure: storage);
    expect(await afterRestart.getApiKey(), 'AIzaSyTESTKEY-0123456789');
    expect(afterRestart.keyUnreadable, isFalse);
  });

  test('a key that cannot be decrypted is reported, not thrown', () async {
    final storage = _FakeStorage(throwOnRead: true);
    final settings = SettingsService(secure: storage);

    // This used to be an exception inside app startup, which is how a saved
    // key looked like it had silently disappeared.
    final key = await settings.getApiKey();
    expect(key, isNull);
    expect(settings.keyUnreadable, isTrue);
    // The unreadable entry is cleared so the next save can succeed.
    expect(storage.deleted, contains('gemini_api_key'));
  });

  test('a write that does not persist is not reported as saved', () async {
    final settings = SettingsService(secure: _FakeStorage(dropWrites: true));

    expect(await settings.setApiKey('AIzaSyTESTKEY-0123456789'), isFalse,
        reason: 'the round trip failed, so nothing was saved');
    expect(settings.keyUnreadable, isTrue);
    expect(await settings.getApiKey(), isNull);
  });

  test('clearing the key works and stays cleared', () async {
    final storage = _FakeStorage();
    final settings = SettingsService(secure: storage);
    await settings.setApiKey('AIzaSyTESTKEY-0123456789');

    expect(await settings.setApiKey(''), isTrue);
    expect(await settings.getApiKey(), isNull);
    expect(storage.values.containsKey('gemini_api_key'), isFalse);
  });

  test('empty or whitespace input is treated as no key', () async {
    final settings = SettingsService(secure: _FakeStorage());
    expect(await settings.setApiKey('   '), isTrue);
    expect(await settings.getApiKey(), isNull);
  });

  group('the engine address is normalized in one place', () {
    test('the shapes a person actually types all mean one address', () {
      for (final typed in const [
        '192.168.1.20',
        '192.168.1.20:5005',
        '192.168.1.20:5005/',
        '  192.168.1.20:5005  ',
        'http://192.168.1.20:5005',
        'http://192.168.1.20:5005/',
        '192.168.1.20/',
        'http://192.168.1.20',
      ]) {
        expect(
          SettingsService.normalizeEngineBase(typed),
          'http://192.168.1.20:5005',
          reason: '"$typed" is the same engine, so it must be one address',
        );
      }
    });

    test('a host name works, and so does an explicit port and https', () {
      expect(
        SettingsService.normalizeEngineBase('engine.lan'),
        'http://engine.lan:5005',
      );
      expect(
        SettingsService.normalizeEngineBase('engine.lan:6000'),
        'http://engine.lan:6000',
      );
      expect(
        SettingsService.normalizeEngineBase('https://engine.lan:5005/'),
        'https://engine.lan:5005',
      );
      // A bracketed IPv6 literal: the colons inside it are not a port.
      expect(
        SettingsService.normalizeEngineBase('[fe80::1]:5005'),
        'http://[fe80::1]:5005',
      );
    });

    test('a typed path or query is not silently kept as part of the base', () {
      expect(
        SettingsService.normalizeEngineBase('http://engine.lan:5005/health'),
        'http://engine.lan:5005',
      );
      expect(
        SettingsService.normalizeEngineBase('engine.lan:5005/?x=1'),
        'http://engine.lan:5005',
      );
    });

    test('input that could never be called is refused, not normalized',
        () {
      for (final unusable in const [
        '',
        '   ',
        'ftp://engine.lan:5005',
        'ws://engine.lan:5005',
        'http://',
        'http://:5005',
        'engine.lan:not-a-port',
        'engine.lan:0',
        'engine.lan:99999',
      ]) {
        expect(
          SettingsService.normalizeEngineBase(unusable),
          isNull,
          reason: '"$unusable" is not an address the app can call',
        );
      }
    });

    test('a refused address leaves the last good one in place', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsService(secure: _FakeStorage());
      await settings.load();
      await settings.setEngineBase('192.168.1.20:5005');

      await settings.setEngineBase('ftp://192.168.1.20:5005');
      expect(settings.engineBase, 'http://192.168.1.20:5005',
          reason: 'a scheme that cannot work must not be stored');
      expect(settings.engineBaseError, isNotEmpty,
          reason: 'the user is told why the value was refused');

      await settings.setEngineBase('   ');
      expect(settings.engineBase, 'http://192.168.1.20:5005');
      expect(settings.engineBaseError, isNotEmpty);

      await settings.setEngineBase('10.0.2.2');
      expect(settings.engineBase, 'http://10.0.2.2:5005');
      expect(settings.engineBaseError, isEmpty,
          reason: 'a good address clears the previous complaint');
    });

    test('a saved address is normalized on load, not only on save', () async {
      // A value written by an older build, or edited by hand in the prefs.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'engine_base': '  192.168.1.20:5005/  ',
      });
      final settings = SettingsService(secure: _FakeStorage());
      await settings.load();
      expect(settings.engineBase, 'http://192.168.1.20:5005');
    });

    test('an unusable saved address falls back instead of propagating',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'engine_base': 'ftp://192.168.1.20:5005',
      });
      final settings = SettingsService(secure: _FakeStorage());
      await settings.load();
      expect(settings.engineBase, SettingsService.defaultEngineBase());
    });

    test('the installer address is normalized on the same rules', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final root = await Directory.systemTemp.createTemp('nb-engine-cfg');
      addTearDown(() => root.deleteSync(recursive: true));
      final config = Directory('${root.path}${Platform.pathSeparator}config')
        ..createSync();
      final file = File('${config.path}${Platform.pathSeparator}install.json')
        ..writeAsStringSync(jsonEncode({'engineBase': ' 192.168.7.7/ '}));

      final settings = SettingsService(
        secure: _FakeStorage(),
        installConfigPath: file.path,
      );
      await settings.load();
      expect(settings.engineBase, 'http://192.168.7.7:5005');
    });

    test('an address the user chose still beats the installer', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'engine_base': '10.1.1.1:5005',
      });
      final root = await Directory.systemTemp.createTemp('nb-engine-cfg2');
      addTearDown(() => root.deleteSync(recursive: true));
      final config = Directory('${root.path}${Platform.pathSeparator}config')
        ..createSync();
      final file = File('${config.path}${Platform.pathSeparator}install.json')
        ..writeAsStringSync(jsonEncode({'engineBase': '192.168.7.7:5005'}));

      final settings = SettingsService(
        secure: _FakeStorage(),
        installConfigPath: file.path,
      );
      await settings.load();
      expect(settings.engineBase, 'http://10.1.1.1:5005');
    });
  });

  group('one unreadable credential does not take the rest with it', () {
    test('the load completes and every other setting is there', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'gemini_model': 'gemini-3.6-flash',
        'output_dir': 'C:/mine',
        'default_target': 'cisco-ssh',
        'context_budget': 12345,
      });
      final settings = SettingsService(
        secure: _FakeStorage(throwOnKeys: {'gns3_pass'}),
      );

      // A device whose keystore cannot read one entry. Before, this threw out
      // of load() and the whole configuration looked lost.
      await settings.load();

      expect(settings.loaded, isTrue);
      expect(settings.model, 'gemini-3.6-flash');
      expect(settings.outputDir, 'C:/mine');
      expect(settings.defaultTarget, 'cisco-ssh');
      expect(settings.contextBudget, 12345);
      expect(settings.loadError, isNotEmpty,
          reason: 'the user is told something was not read');
    });

    test('the reported error is safe to show and to paste in a bug report',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsService(
        secure: _FakeStorage(
          throwOnKeys: {'gns3_pass'},
          readFailureText: 'PlatformException(keychain): gns3_pass AIzaSecret',
        ),
      );
      await settings.load();

      expect(settings.loadError, isNotEmpty);
      expect(settings.loadError, isNot(contains('AIzaSecret')),
          reason: 'a keystore error can quote the value it failed on, and '
              'this string is shown in the UI and pasted into reports');
      expect(settings.loadError, isNot(contains('gns3_pass')));
    });

    test('a credential that cannot be migrated is kept in prefs, not lost',
        () async {
      // The plaintext migration path: the secure read fails, so the old value
      // has to stay usable instead of being cleared by a failed write.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'gns3_user': 'labadmin',
        'gns3_pass': 's3cret',
      });
      final storage = _FakeStorage(
        dropWriteKeys: {'gns3_user', 'gns3_pass'},
      );
      final settings = SettingsService(secure: storage);
      await settings.load();

      expect(settings.gns3User, 'labadmin');
      expect(settings.gns3Pass, 's3cret',
          reason: 'a failed migration must not lose the credential');
      expect(storage.values.containsKey('gns3_user'), isFalse,
          reason: 'nothing claims to be in secure storage when it is not');
    });

    test('a healthy load reports no error at all', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsService(secure: _FakeStorage());
      await settings.load();
      expect(settings.loadError, isEmpty);
    });
  });
}
