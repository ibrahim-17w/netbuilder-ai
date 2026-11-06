import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/pkt/pkt_engine_builder.dart';
import 'package:net_builder/services/pkt/template_library.dart';

/// The devices the user-supplied `test.pkt` added to the template library:
/// a real Printer-PT and the end devices the app previously could not place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the parser understands the newly harvested device kinds', () {
    final plan = NetworkIntent.parseSimple(
      'harvested-devices',
      CasualEnglish.normalize(
        '1 printer, 1 meraki server, 1 tv, 1 analog phone, '
        '1 voip adapter, 1 wired end device, 1 wireless end device',
      ),
    );

    int count(String type) => plan.nodes.where((n) => n.type == type).length;
    expect(count('printer'), 1);
    expect(count('meraki-server'), 1);
    expect(count('tv'), 1);
    expect(count('analog-phone'), 1);
    expect(count('voip-adapter'), 1);
    expect(count('wired-end-device'), 1);
    expect(count('wireless-end-device'), 1);
  });

  test('the bundled library contains the harvested printer block', () async {
    final library = await PktTemplateLibrary.loadBundled();
    expect(
      library.devices.where((device) => device.model == 'Printer-PT'),
      isNotEmpty,
    );
  });

  test('a printer plan cabled through a switch builds in Dart', () async {
    final library = await PktTemplateLibrary.loadBundled();
    final built = await buildPkt(
      plan: {
        'steps': [
          {
            'action': 'create_nodes',
            'nodes': [
              {'name': 'R1', 'type': 'router', 'model': '2911', 'exactModel': true},
              {
                'name': 'SW1',
                'type': 'switch',
                'model': '2960',
                'exactModel': true,
              },
              {
                'name': 'PRN1',
                'type': 'printer',
                'model': 'Printer-PT',
                'exactModel': true,
              },
            ],
          },
          {
            'action': 'create_links',
            'links': [
              {'a': 'R1', 'aIf': 'g0/0', 'b': 'SW1', 'bIf': 'g0/1'},
              {'a': 'SW1', 'aIf': 'f0/1', 'b': 'PRN1', 'bIf': 'f0'},
            ],
          },
        ],
      },
      library: library,
      project: 'printer-dart',
    );

    expect(built.deviceCount, 3);
    expect(built.linkCount, 2);
    expect(built.xml, contains('Printer-PT'));
  });
}
