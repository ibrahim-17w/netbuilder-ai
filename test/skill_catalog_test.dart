import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/skill_catalog.dart';

/// The "/" menu is a promise list: everything in it must be a path the app
/// really takes - a slash command the chat handles, or a sentence the
/// offline readers answer.
void main() {
  group('SkillCatalog', () {
    test('every skill is complete, unique and invocable', () {
      expect(SkillCatalog.all, isNotEmpty);
      final commands = <String>{};
      for (final skill in SkillCatalog.all) {
        expect(skill.title, isNotEmpty);
        expect(skill.detail, isNotEmpty);
        expect(skill.category, isNotEmpty);
        expect(skill.send.trim(), isNotEmpty, reason: skill.title);
        if (skill.command.isNotEmpty) {
          expect(
            commands.add(skill.command),
            isTrue,
            reason: 'duplicate command ${skill.command}',
          );
          expect(
            skill.send.trim(),
            skill.command.trim(),
            reason: 'a command skill must send exactly its command',
          );
        }
      }
    });

    test('the headline capabilities are all present', () {
      // Packet Tracer read and write.
      expect(
        SkillCatalog.all.any((s) => s.command.trim() == '/scan'),
        isTrue,
        reason: 'read a .pkt',
      );
      expect(
        SkillCatalog.all.any((s) => s.command.trim() == '/build'),
        isTrue,
        reason: 'write a .pkt',
      );
      // GNS3, real Cisco gear and the other targets.
      final targets = SkillCatalog.all
          .map((s) => s.command)
          .where((c) => c.startsWith('/target '))
          .toSet();
      expect(targets, contains('/target gns3'));
      expect(targets, contains('/target cisco-ssh'));
      expect(targets, contains('/target packet-tracer'));
      expect(targets, contains('/target aws-vpc'));
      // Design advice and troubleshooting, answered offline.
      expect(
        SkillCatalog.all.any((s) => s.send.contains('router should I use')),
        isTrue,
      );
      expect(
        SkillCatalog.all.any((s) => s.send.contains('slow')),
        isTrue,
      );
    });

    test('the menu opens on "/" and narrows with the token', () {
      expect(SkillCatalog.match('/').length, SkillCatalog.all.length);
      expect(SkillCatalog.match('/bu').map((s) => s.command), contains('/build'));
      expect(SkillCatalog.match('/t').length, greaterThan(1),
          reason: 'the four targets share the token');
      expect(SkillCatalog.match('/zzz'), isEmpty);
      expect(SkillCatalog.match('/scan '), isEmpty,
          reason: 'a space means the argument started - the menu steps aside');
      expect(SkillCatalog.match('hello'), isEmpty);
      expect(SkillCatalog.match('/bu\nnext line'), isEmpty,
          reason: 'Enter means send, never more menu');
    });

    test('the chat list names every category and command', () {
      final md = SkillCatalog.asMarkdown();
      expect(md, contains('`/build`'));
      expect(md, contains('`/scan`'));
      expect(md, contains('`/target gns3`'));
      expect(md, contains('Packet Tracer'));
      expect(md, contains('Design advice'));
      expect(md, contains('Addressing'));
      expect(md, contains('Troubleshooting'));
    });
  });
}
