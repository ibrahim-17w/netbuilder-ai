import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/pkt_plan_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String device({
    required String name,
    required String model,
    required String type,
    required String ref,
    List<String> config = const [],
    String extra = '',
  }) =>
      '<DEVICE><ENGINE>'
      '<TYPE model="$model" customModel="">$type</TYPE>'
      '<NAME translate="true">$name</NAME>'
      '<SAVE_REF_ID>save-ref-id:$ref</SAVE_REF_ID>'
      '$extra'
      '<RUNNINGCONFIG>${config.map((line) => '<LINE>$line</LINE>').join()}</RUNNINGCONFIG>'
      '</ENGINE></DEVICE>';

  test('converts device identity, exact cable endpoints, and IOS addresses', () {
    final xml =
        '<PACKETTRACER5><NETWORK><DEVICES>'
        '${device(name: 'R1', model: '2911', type: 'Router', ref: '1', config: ['interface GigabitEthernet0/0', ' ip address 10.4.0.1 255.255.255.252', ' clock rate 64000', 'router ospf 10'])}'
        '${device(name: 'SW1', model: '2960', type: 'Switch', ref: '2')}'
        '</DEVICES><LINKS><LINK>'
        '<FROM>save-ref-id:1</FROM><PORT>GigabitEthernet0/0</PORT>'
        '<TO>save-ref-id:2</TO><PORT>GigabitEthernet0/1</PORT>'
        '<TYPE>eCopper</TYPE><TYPE>eCrossOver</TYPE>'
        '</LINK></LINKS></NETWORK></PACKETTRACER5>';

    final imported = PktPlanImportService.fromBytes(
      encryptPkt(xml),
      projectName: 'branch',
    );
    final plan = imported.intent;

    expect(plan.projectName, 'branch');
    expect(plan.nodes.map((node) => node.name), ['R1', 'SW1']);
    expect(plan.nodes.map((node) => node.model), ['2911', '2960']);
    expect(plan.nodes.map((node) => node.type), ['router', 'switch']);
    expect(plan.routing, 'ospf');
    expect(plan.addressing.single.ipCidr, '10.4.0.1/30');
    expect(plan.links.single.a, 'R1');
    expect(plan.links.single.b, 'SW1');
    expect(plan.links.single.aIf, 'GigabitEthernet0/0');
    expect(plan.links.single.bIf, 'GigabitEthernet0/1');
    expect(plan.links.single.cable, 'copper-cross');
    expect(plan.links.single.exactPorts, isTrue);
    expect(imported.limitations, isNotEmpty);
  });

  test('does not invent a topology for an unreadable or empty save', () {
    expect(
      () => PktPlanImportService.fromXml(
        '<PACKETTRACER5><NETWORK/></PACKETTRACER5>',
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('keeps recognized enabled server roles in the editable plan', () {
    final xml =
        '<PACKETTRACER5><NETWORK><DEVICES>'
        '${device(name: 'WEB1', model: 'Server-PT', type: 'Server', ref: '7', extra: '<HTTP_SERVER><ENABLED>1</ENABLED></HTTP_SERVER>'
            '<DNS_SERVER><ENABLED>1</ENABLED></DNS_SERVER>')}'
        '</DEVICES></NETWORK></PACKETTRACER5>';
    final imported = PktPlanImportService.fromXml(xml);

    expect(imported.intent.nodes.single.services, containsAll(['http', 'dns']));
    expect(imported.limitations.join(' '), contains('Service-pool records'));
  });

  test('preserves installed modules and canvas positions', () {
    final xml =
        '<PACKETTRACER5><NETWORK><DEVICES>'
        '${device(name: 'R1', model: '2911', type: 'Router', ref: '1', extra: '<SLOT><MODEL>WIC-2T</MODEL></SLOT><LOGICAL><X>132</X><Y>284</Y></LOGICAL>')}'
        '</DEVICES></NETWORK></PACKETTRACER5>';

    final imported = PktPlanImportService.fromXml(xml);

    expect(imported.intent.nodes.single.modules, contains('WIC-2T'));
    expect(imported.intent.layout['R1'], const Offset(132, 284));
    expect(
      imported.preservedDetails,
      contains(
        'Installed hardware modules and saved canvas positions where present.',
      ),
    );
  });

  test('large imports can be parsed in a background isolate', () async {
    final xml =
        '<PACKETTRACER5><NETWORK><DEVICES>'
        '${device(name: 'R1', model: '2911', type: 'Router', ref: '1', extra: '<SLOT><MODEL>WIC-2T</MODEL></SLOT><LOGICAL><X>132</X><Y>284</Y></LOGICAL>')}'
        '</DEVICES></NETWORK></PACKETTRACER5>';
    final stages = <String>[];

    final imported = await PktPlanImportService.fromBytesInBackground(
      encryptPkt(xml),
      projectName: 'worker import',
      forceIsolate: true,
      onProgress: (stage, _) => stages.add(stage),
    );

    expect(imported.intent.projectName, 'worker import');
    expect(imported.intent.nodes.single.modules, contains('WIC-2T'));
    expect(imported.intent.layout['R1'], const Offset(132, 284));
    expect(stages, contains('Decrypting the Packet Tracer save'));
  });
}
