import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/credential_redaction.dart';

void main() {
  test('redacts sk-, Bearer, API-key and Google key shapes', () {
    const inputs = [
      'request failed: sk-live-abcdefgh12345678',
      'Authorization: Bearer abc.def.ghi+123/xyz=',
      'api_key=sk-proj-abcdefgh12345678',
      '{"apiKey": "sk-ant-abcdefgh12345678"}',
      '{"password": "Sup3rSecret!"}',
      'x-goog-api-key: AIzaabcdefghijklmnopqrstuvwxyz123456',
      'password=Sup3rSecret!',
    ];
    for (final input in inputs) {
      final red = CredentialRedaction.redact(input);
      expect(red, contains(CredentialRedaction.marker), reason: input);
      for (final secret in const [
        'sk-live-abcdefgh12345678',
        'abc.def.ghi+123/xyz=',
        'sk-proj-abcdefgh12345678',
        'sk-ant-abcdefgh12345678',
        'AIzaabcdefghijklmnopqrstuvwxyz123456',
        'Sup3rSecret!',
      ]) {
        expect(red, isNot(contains(secret)), reason: input);
      }
    }
  });

  test('redaction is idempotent and leaves ordinary text alone', () {
    const ordinary = 'R1 has 2 interfaces and OSPF is up';
    expect(CredentialRedaction.redact(ordinary), ordinary);

    const once = 'apiKey=sk-live-abcdefgh12345678';
    final red = CredentialRedaction.redact(once);
    expect(CredentialRedaction.redact(red), red);
  });
}
