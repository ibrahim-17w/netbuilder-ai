import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/pkt_import_request.dart';
import 'package:net_builder/services/pkt_plan_import_service.dart';

/// "Use this file as my lab" adopts the scanned capture as the standing
/// plan: the reader must catch the adoption phrases and nothing else, and
/// the reply must state what was kept, what was not, and what it replaced.
void main() {
  group('PktImportRequest.matches', () {
    test('adoption phrases are caught', () {
      const yes = [
        'use this file as my lab',
        'use the capture as the plan',
        'make this file my lab',
        'make that the plan',
        'set this scan as my lab',
        'import this file',
        'take the save as the network',
        'use this file as the standing plan',
      ];
      for (final text in yes) {
        expect(PktImportRequest.matches(text), isTrue, reason: text);
      }
    });

    test('builds, edits and questions are not adoption requests', () {
      const no = [
        'build the .pkt',
        'build the lab file',
        'edit the file and add a server',
        'use this file to make a new lab with 2 routers',
        'what does this file contain?',
        'why is the link down?',
        'add a switch',
        'hello',
        'use this password in the lab',
      ];
      for (final text in no) {
        expect(PktImportRequest.matches(text), isFalse, reason: text);
      }
    });

    test('multi-line text is never an adoption request', () {
      expect(PktImportRequest.matches('use this file\nas my lab'), isFalse);
    });
  });

  group('PktImportReply.text', () {
    test('names the file, the counts, and the next steps', () {
      const imported = ImportedPktPlan(
        intent: NetworkIntent(
          projectName: 'office',
          nodes: [
            NetNode(name: 'R1', type: 'router'),
            NetNode(name: 'SW1', type: 'switch'),
          ],
          links: [NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1')],
        ),
        preservedDetails: ['device models', 'interface addresses'],
        limitations: ['service panels', 'scenario state'],
      );
      final text = PktImportReply.text(imported, fileName: 'office.pkt');
      expect(text, contains('**office.pkt is the lab now.**'));
      expect(text, contains('2 device(s)'));
      expect(text, contains('1 link(s)'));
      expect(text, contains('device models'));
      expect(text, contains('service panels'));
      expect(text, contains('how do I build this?'));
    });

    test('says what it replaced when a plan was standing', () {
      const imported = ImportedPktPlan(
        intent: NetworkIntent(
          projectName: 'imported',
          nodes: [NetNode(name: 'R1', type: 'router')],
        ),
        limitations: [],
      );
      final replaced = NetworkIntent.parseSimple('p', '2 routers 4 switches');
      final text = PktImportReply.text(
        imported,
        fileName: 'lab.pkt',
        replaced: replaced,
      );
      expect(text, contains('replaces the plan that was standing'));
      expect(text, contains('6 device(s)'));
      expect(text, contains('undo that'));
    });

    test('no replacement warning when nothing stood', () {
      const imported = ImportedPktPlan(
        intent: NetworkIntent(
          projectName: 'imported',
          nodes: [NetNode(name: 'R1', type: 'router')],
        ),
        limitations: [],
      );
      final text = PktImportReply.text(imported, fileName: 'lab.pkt');
      expect(text, isNot(contains('replaces')));
    });
  });
}
