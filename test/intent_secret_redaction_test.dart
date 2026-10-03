import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';

/// A brief is the one place people type credentials, and the plan notes quote
/// the brief back verbatim. Those notes are persisted with the build record,
/// exported to JSON and shown next to the plan - so a password written into a
/// note was a password in clear text in the database and in every export,
/// which is the one thing `includeSecrets: false` promises will not happen.
void main() {
  group('the ways a brief names a credential', () {
    test('each one is replaced by the marker', () {
      const cases = <String, String>{
        'password H0unter2': 'password [redacted]',
        'Password: H0unter2': 'Password: [redacted]',
        'the aaa password is S3cret!': 'the aaa password is [redacted]',
        'enable secret Cl@ss1': 'enable secret [redacted]',
        'shared key LabKey1': 'shared key [redacted]',
        'pre-shared key LabKey1': 'pre-shared key [redacted]',
        'psk LabKey1': 'psk [redacted]',
        'secret is 5': 'secret is [redacted]',
        'key = cisco123': 'key = [redacted]',
        'the password "two words" stays one value':
            'the password [redacted] stays one value',
      };
      cases.forEach((brief, expected) {
        expect(NetworkIntent.redactSecrets(brief), expected,
            reason: 'redacted: $brief');
      });
    });

    test('the marker is used, not an empty string or a star', () {
      final redacted = NetworkIntent.redactSecrets('password H0unter2');
      expect(redacted, contains(NetworkIntent.redacted));
      expect(redacted, isNot(contains('H0unter2')));
    });

    test('a sentence about a password is not mangled', () {
      // "password policy" and "the same shared key on both ends" mention a
      // secret and supply none. Replacing the next word there would corrupt
      // the note without hiding anything.
      const untouched = [
        'the password policy must be documented',
        'using the same shared key on the server and the router',
        'the enable secret must differ per device',
        'passwords are never echoed into notes',
        'a compass and a pass route through the top',
      ];
      for (final sentence in untouched) {
        expect(NetworkIntent.redactSecrets(sentence), sentence,
            reason: 'left as written: $sentence');
      }
    });
  });

  group('the notes a plan carries', () {
    test('the brief quoted into a note is redacted there', () {
      final intent = NetworkIntent.parseSimple(
        'lab',
        '2 routers 1 switch aaa, username admin password H0unter2',
      );
      final note = intent.notes.first;
      expect(note, startsWith('parsed offline from:'));
      expect(note, isNot(contains('H0unter2')),
          reason: 'the stored note must not carry the password');
      expect(note, contains(NetworkIntent.redacted));
      // The rest of the brief is still readable - redaction is not deletion.
      expect(note, contains('2 routers'));
    });

    test('a portable export redacts a note from any source', () {
      const intent = NetworkIntent(
        projectName: 'lab',
        notes: ['parsed offline from: aaa with enable secret Cl@ss1'],
        security: SecurityIntent(consolePassword: true, enableSecret: 'Cl@ss1'),
      );

      final portable = intent.toJson(includeSecrets: false);
      expect((portable['notes'] as List).first, isNot(contains('Cl@ss1')));
      expect((portable['notes'] as List).first,
          contains(NetworkIntent.redacted));
      expect(
        (portable['security'] as Map).containsKey('enableSecret'),
        isFalse,
      );
    });

    test('the local intent still has the real credential', () {
      // Redaction is about what is written down and exported, not about the
      // executor: the adapter still has to be able to type the password.
      const intent = NetworkIntent(
        projectName: 'lab',
        notes: ['parsed offline from: aaa with enable secret Cl@ss1'],
        security: SecurityIntent(consolePassword: true, enableSecret: 'Cl@ss1'),
      );
      final full = intent.toJson();
      expect((full['security'] as Map)['enableSecret'], 'Cl@ss1');
      expect((full['notes'] as List).first, contains('Cl@ss1'));

      // A planner payload is the portable shape, so it is redacted too.
      final planner = intent.toPlannerJson();
      expect((planner['notes'] as List).first, isNot(contains('Cl@ss1')));
      expect((planner['security'] as Map).containsKey('enableSecret'), isFalse);
    });
  });
}
