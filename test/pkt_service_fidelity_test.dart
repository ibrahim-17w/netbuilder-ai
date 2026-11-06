import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/pkt/pkt_engine_builder.dart';
import 'package:net_builder/services/pkt/template_library.dart';
import 'package:net_builder/services/pkt_plan_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('server DHCP and DNS survive build, import and rebuild', () async {
    const pools = [
      {
        'poolName': 'Staff',
        'startIp': '192.168.1.50',
        'mask': '255.255.255.0',
        'gateway': '192.168.1.1',
        'dnsServer': '192.168.1.10',
        'maxUsers': 35,
      },
    ];
    const records = [
      {'name': 'web.lab.test', 'address': '192.168.1.20'},
    ];
    const plan = NetworkIntent(
      projectName: 'fidelity',
      nodes: [
        NetNode(
          name: 'SRV1',
          type: 'server',
          model: 'Server-PT',
          exactModel: true,
          services: ['dhcp', 'dns'],
          serviceRules: {
            'dhcp': {'pools': pools},
            'dns': {'records': records},
          },
        ),
      ],
    );
    final library = await PktTemplateLibrary.loadBundled();
    Future<String> compile(NetworkIntent intent) async {
      final built = await buildPkt(
        plan: PacketTracerAdapter.autopilotPlan(intent),
        library: library,
        project: 'fidelity',
      );
      expect(built.warnings, isEmpty, reason: built.warnings.join('; '));
      return built.xml;
    }

    final first = await compile(plan);
    final imported = PktPlanImportService.fromXml(first);
    expect(
      imported.intent.nodes.single.type,
      'server',
      reason: imported.intent.nodes.single.toJson().toString(),
    );
    expect(imported.intent.nodes.single.services, containsAll(['dhcp', 'dns']));
    expect(
      (imported.intent.nodes.single.serviceRules['dhcp'] as Map)['pools'],
      pools,
    );
    expect(
      (imported.intent.nodes.single.serviceRules['dns'] as Map)['records'],
      records,
    );
    final rebuilt = PktPlanImportService.fromXml(
      await compile(imported.intent),
    );
    expect(
      rebuilt.intent.nodes.single.serviceRules,
      imported.intent.nodes.single.serviceRules,
    );
    expect(imported.limitations, isNotEmpty);
  });
}
