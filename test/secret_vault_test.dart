import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/secret_vault.dart';

void main() {
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
}
