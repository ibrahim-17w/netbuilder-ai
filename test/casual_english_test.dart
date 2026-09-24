import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/casual_english.dart';

void main() {
  group('casual English normalizer', () {
    test('expands shorthand without losing the numbers', () {
      expect(
        CasualEnglish.normalize('u wanna 2 routers'),
        contains('you want to 2 routers'),
      );
      expect(CasualEnglish.normalize('i dont know what to do'),
          contains('i do not know'));
    });

    test('fixes common device typos', () {
      final n = CasualEnglish.normalize('swtich and 2 routrs');
      expect(n, contains('switch'));
      expect(n, contains('routers'));
    });

    test('never damages data tokens', () {
      expect(CasualEnglish.normalize('lan 192.168.1.0/24'),
          contains('192.168.1.0/24'));
      expect(CasualEnglish.normalize('2 routers'), contains('2 routers'));
      expect(CasualEnglish.normalize('password LabAdmin2026'),
          contains('LabAdmin2026'));
      // A mixed-case word with no digits is treated as deliberate (a secret).
      expect(CasualEnglish.normalize('key SecretPass'), contains('SecretPass'));
    });

    test('drops filler with no plan meaning', () {
      expect(CasualEnglish.normalize('make it normal'), isEmpty);
      final n = CasualEnglish.normalize('2 routers and other stuff');
      expect(n, contains('2 routers'));
      expect(n, isNot(contains('other stuff')));
    });
  });
}
