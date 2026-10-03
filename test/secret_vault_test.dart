import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/secret_vault.dart';

/// An in-memory key store, so the lifecycle of a project slot can be checked
/// without the platform keystore (and without a device).
class _FakeStorage extends FlutterSecureStorage {
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
  }) async =>
      values[key];

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
  late _FakeStorage storage;
  // Every test installs its own store, so nothing is left behind.
  setUp(() => SecretVault.storage = storage = _FakeStorage());

  test('extract pulls AAA and VPN secrets from an intent json', () {
    final secrets = SecretVault.extract({
      'projectName': 'lab',
      'security': {
        'aaa': true,
        'aaaPassword': 's3cret',
        'vpnPreSharedKey': 'psk-123',
        'aaaUsername': 'admin',
      },
    });
    expect(secrets, {'aaaPassword': 's3cret', 'vpnPreSharedKey': 'psk-123'});
  });

  test('extract ignores intents with no secrets', () {
    expect(
      SecretVault.extract({
        'projectName': 'lab',
        'security': {'aaa': true},
      }),
      isEmpty,
    );
    expect(SecretVault.extract({'projectName': 'lab'}), isEmpty);
  });

  test('inject puts secrets back without clobbering existing values', () {
    final merged = SecretVault.inject(
      {
        'projectName': 'lab',
        'security': <String, dynamic>{'aaa': true},
      },
      {'aaaPassword': 'restored', 'vpnPreSharedKey': 'psk'},
    );
    final security = merged['security'] as Map<String, dynamic>;
    expect(security['aaaPassword'], 'restored');
    expect(security['vpnPreSharedKey'], 'psk');
    expect(security['aaa'], true);
  });

  test('inject with no secrets returns the input untouched', () {
    final input = <String, dynamic>{'projectName': 'lab'};
    expect(SecretVault.inject(input, const {}), same(input));
  });

  group('a project slot is replaced, not added to', () {
    test('secrets round trip through the keychain', () async {
      await SecretVault.store('Office Lab', const {
        'aaaPassword': 's3cret',
        'vpnPreSharedKey': 'psk-123',
      });
      expect(await SecretVault.load('office lab'),
          {'aaaPassword': 's3cret', 'vpnPreSharedKey': 'psk-123'});
    });

    test('a secret dropped from a re-saved intent is gone from the vault',
        () async {
      await SecretVault.store('lab', const {
        'aaaPassword': 's3cret',
        'vpnPreSharedKey': 'psk-123',
      });

      // The user removed the pre-shared key from the brief and the project was
      // saved again. The intent no longer carries a value to overwrite, which
      // is why writing only what it was given left the key in the keychain.
      await SecretVault.store('lab', const {'aaaPassword': 's3cret'});

      expect(await SecretVault.load('lab'), {'aaaPassword': 's3cret'});
      expect(storage.values.values, isNot(contains('psk-123')));
    });

    test('saving a project with no secrets at all leaves nothing behind',
        () async {
      await SecretVault.store('lab', const {
        'aaaPassword': 's3cret',
        'vpnPreSharedKey': 'psk-123',
      });
      await SecretVault.store('lab', const {});

      expect(await SecretVault.load('lab'), isEmpty);
      expect(storage.values, isEmpty);
    });

    test('an empty value clears its own slot', () async {
      await SecretVault.store('lab', const {
        'aaaPassword': 's3cret',
        'vpnPreSharedKey': 'psk-123',
      });
      await SecretVault.store('lab', const {
        'aaaPassword': '',
        'vpnPreSharedKey': 'psk-123',
      });
      expect(await SecretVault.load('lab'), {'vpnPreSharedKey': 'psk-123'});
    });

    test('projects do not share a slot', () async {
      await SecretVault.store('lab-a', const {'aaaPassword': 'one'});
      await SecretVault.store('lab-b', const {'aaaPassword': 'two'});
      expect(await SecretVault.load('lab-a'), {'aaaPassword': 'one'});
      expect(await SecretVault.load('lab-b'), {'aaaPassword': 'two'});
    });

    test('purge removes every secret of that project and no other', () async {
      await SecretVault.store('lab', const {
        'aaaPassword': 's3cret',
        'vpnPreSharedKey': 'psk-123',
      });
      await SecretVault.store('other', const {'aaaPassword': 'keep'});

      await SecretVault.purge('lab');

      expect(await SecretVault.load('lab'), isEmpty);
      expect(await SecretVault.load('other'), {'aaaPassword': 'keep'});
    });
  });
}
