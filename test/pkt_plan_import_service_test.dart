import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/pkt_plan_import_service.dart';
import 'package:net_builder/services/validator_service.dart';

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

  String serverWithDhcpDns() =>
      '<PACKETTRACER5><NETWORK><DEVICES>'
      '${device(name: 'SRV1', model: 'Server-PT', type: 'Server', ref: '9', config: const ['ip dhcp pool LAN', ' network 192.168.1.0 255.255.255.0', ' default-router 192.168.1.1', ' dns-server 192.168.1.53', '!', 'ip dns server', 'ip host pc1 192.168.1.10', 'ip host pc2 192.168.1.11'])}'
      '</DEVICES></NETWORK></PACKETTRACER5>';

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

  test('keeps saved DHCP pools and DNS records from a device config', () {
    final imported = PktPlanImportService.fromXml(serverWithDhcpDns());
    final node = imported.intent.nodes.single;

    expect(node.services, containsAll(['dhcp', 'dns']));
    final pool = Map<String, dynamic>.from(
      ((node.serviceRules['dhcp'] as Map)['pools'] as List).single as Map,
    );
    expect(pool['poolName'], 'LAN');
    expect(pool['startIp'], '192.168.1.1');
    expect(pool['mask'], '255.255.255.0');
    expect(pool['gateway'], '192.168.1.1');
    expect(pool['dnsServer'], '192.168.1.53');
    expect(pool.containsKey('maxUsers'), isFalse);
    final records = ((node.serviceRules['dns'] as Map)['records'] as List)
        .map((record) => Map<String, dynamic>.from(record as Map))
        .toList();
    expect(records, [
      {'name': 'pc1', 'address': '192.168.1.10'},
      {'name': 'pc2', 'address': '192.168.1.11'},
    ]);
  });

  test('uses the pool and record keys the build path consumes', () {
    final imported = PktPlanImportService.fromXml(serverWithDhcpDns());
    final node = imported.intent.nodes.single;

    final pool = Map<String, dynamic>.from(
      ((node.serviceRules['dhcp'] as Map)['pools'] as List).single as Map,
    );
    expect(pool.keys.toSet(), {
      'poolName',
      'startIp',
      'mask',
      'gateway',
      'dnsServer',
    });
    expect(
      ((node.serviceRules['dns'] as Map)['records'] as List).map(
        (record) => Map<String, dynamic>.from(record as Map).keys.toSet(),
      ),
      everyElement({'name', 'address'}),
    );
  });

  test('leaves devices without saved DHCP or DNS config unchanged', () {
    final xml =
        '<PACKETTRACER5><NETWORK><DEVICES>'
        '${device(name: 'R1', model: '2911', type: 'Router', ref: '3', config: ['interface GigabitEthernet0/0', ' ip address 10.4.0.1 255.255.255.252', ' ip dhcp excluded-address 10.4.0.1 10.4.0.5'])}'
        '</DEVICES></NETWORK></PACKETTRACER5>';
    final imported = PktPlanImportService.fromXml(xml);
    final node = imported.intent.nodes.single;

    expect(node.services, isNot(contains('dhcp')));
    expect(node.services, isNot(contains('dns')));
    expect(node.serviceRules, isEmpty);
    expect(imported.intent.addressing.single.ipCidr, '10.4.0.1/30');
    expect(imported.preservedDetails.join(' '), isNot(contains('retained on')));
  });

  test('reports retained DHCP and DNS settings in the fidelity note', () {
    final imported = PktPlanImportService.fromXml(serverWithDhcpDns());

    expect(
      imported.preservedDetails,
      contains('DHCP pools retained on SRV1: 1 pool(s).'),
    );
    expect(
      imported.preservedDetails,
      contains('DNS records retained on SRV1: 2 record(s).'),
    );
  });

  test('an imported ROUTER with saved pools validates clean', () {
    // IOS routers serve DHCP and DNS from their own config lines - the
    // Services-tab rule must not make an honest import unbuildable.
    final xml =
        '<PACKETTRACER5><NETWORK><DEVICES>'
        '${device(name: 'R1', model: '2911', type: 'Router', ref: '1', config: const ['ip dhcp pool LAN', ' network 192.168.1.0 255.255.255.0', ' default-router 192.168.1.1', '!'])}'
        '${device(name: 'PC1', model: 'PC-PT', type: 'PC', ref: '2', config: const [])}'
        '</DEVICES><LINKS><LINK>'
        '<FROM>save-ref-id:1</FROM><PORT>GigabitEthernet0/0</PORT>'
        '<TO>save-ref-id:2</TO><PORT>FastEthernet0</PORT>'
        '<TYPE>eCopper</TYPE>'
        '</LINK></LINKS></NETWORK></PACKETTRACER5>';
    final imported = PktPlanImportService.fromBytes(
      encryptPkt(xml),
      projectName: 'router-dhcp',
    );
    final router = imported.intent.nodes.firstWhere((n) => n.type == 'router');
    expect(router.services, contains('dhcp'));
    expect(
      ValidatorService.validate(imported.intent, target: 'packet-tracer')
          .where((issue) => issue.severity == 'error')
          .map((issue) => issue.message)
          .join('\n'),
      isNot(contains('is not a server')),
      reason: 'a router serving DHCP from its own pools is a working design',
    );
  });
}
