import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/settings_service.dart';

/// An in-memory stand-in for the platform key store, with switches for the
/// two ways it fails in the field: a value that cannot be decrypted, and a
/// write that appears to succeed but does not persist.
class _FakeStorage extends FlutterSecureStorage {
  _FakeStorage({this.throwOnRead = false, this.dropWrites = false});

  final bool throwOnRead;
  final bool dropWrites;
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
    if (throwOnRead) {
      throw Exception('javax.crypto.BadPaddingException: could not decrypt');
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
    if (dropWrites) return;
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
}
