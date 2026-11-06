import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';

/// Real-world words for equipment, not just the canonical Packet Tracer
/// names. Each phrase must produce exactly one node of the expected kind:
/// a second node would mean one word matched two kinds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NetworkIntent parse(String brief) => NetworkIntent.parseSimple(
    'vocabulary',
    CasualEnglish.normalize(brief),
  );

  test('common equipment words map to one device each', () {
    const cases = <String, String>{
      '1 NAS': 'server',
      '1 network attached storage': 'server',
      '1 multifunction printer': 'printer',
      '1 NGFW': 'firewall',
      '1 UTM': 'firewall',
      '1 ONT': 'modem',
      '1 broadband modem': 'modem',
      '1 television': 'tv',
      '1 protocol analyzer': 'sniffer',
      '1 packet capture': 'sniffer',
      '1 PDU': 'power-distribution',
      '1 UPS': 'power-distribution',
      '1 telephone': 'phone',
      '1 desk phone': 'phone',
      '1 wired client': 'wired-end-device',
      '1 wireless client': 'wireless-end-device',
      '1 wifi client': 'wireless-end-device',
      '1 MCU': 'mcu',
      '1 microcontroller': 'mcu',
      '1 single board computer': 'sbc',
      '1 cell tower': 'cell-tower',
      '1 central office': 'central-office',
    };

    for (final entry in cases.entries) {
      final plan = parse(entry.key);
      // A peripheral-only brief still gets the planner's tiny-office router
      // and switch. The assertion is that the named kind appears once, not
      // that the whole plan has one node.
      expect(
        plan.nodes.where((n) => n.type == entry.value),
        hasLength(1),
        reason: '${entry.key} should be a ${entry.value}: '
            '${plan.nodes.map((n) => '${n.name}:${n.type}').join(', ')}',
      );
    }
  });

  test('the four template-backed offline kinds survive with their models', () {
    const cases = <String, String>{
      '1 MCU': 'MCU-PT',
      '1 SBC': 'SBC-PT',
      '1 cell tower': 'Cell-Tower',
      '1 central office': 'Central-Office-Server',
    };
    for (final entry in cases.entries) {
      final matching = parse(
        entry.key,
      ).nodes.where((n) => n.model == entry.value);
      expect(matching, hasLength(1), reason: entry.key);
    }
  });
}
