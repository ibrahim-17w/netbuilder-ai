import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/packet_tracer/catalog.dart';
import 'package:net_builder/services/pkt/pkt_engine_builder.dart';
import 'package:net_builder/services/pkt/template_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = PacketTracerCatalog.instance;
  test('aliases retain precise hardware identity', () {
    expect(catalog.device('4331')?.model, 'ISR4331');
    expect(catalog.device('2960')?.model, '2960-24TT');
    for (final device in catalog.devices) {
      expect(catalog.device(device.model), same(device));
    }
  });
  test('every cable alias resolves without an unknown-cable fallback', () {
    for (final cable in catalog.cables) {
      for (final alias in [cable.id, ...cable.aliases]) {
        expect(catalog.cable(alias)?.id, cable.id, reason: alias);
      }
    }
    expect(catalog.cable('magic ethernet'), isNull);
    expect(catalog.cable('console')?.templateAvailable, isFalse);
  });
  test('model quantities and custom names survive the planner', () {
    final plan = NetworkIntent.parseSimple(
      'test',
      'Use 2 2960-24TT switches and 1 ISR4331 router.',
    );
    expect(plan.nodes.where((n) => n.type == 'switch'), hasLength(2));
    expect(
      plan.nodes
          .where((n) => n.type == 'switch')
          .every((n) => n.model == '2960-24TT' && n.exactModel),
      isTrue,
    );
    expect(plan.nodes.where((n) => n.type == 'router').single.model, 'ISR4331');
    final custom = NetworkIntent.parseSimple(
      'test',
      'router named HQ-Core model 2911; switch named Access-A model 2960-24TT; '
          'Connect HQ-Core GigabitEthernet0/0 to Access-A GigabitEthernet0/1 using straight-through.',
    );
    expect(
      custom.nodes.map((n) => n.name),
      containsAll(['HQ-Core', 'Access-A']),
    );
    final link = custom.links.singleWhere(
      (l) => l.a == 'HQ-Core' && l.b == 'Access-A',
    );
    expect(ptPortName(link.aIf), 'gigabitethernet0/0');
    expect(link.cable, 'copper');
    expect(link.exactPorts, isTrue);
    expect(
      custom.wiredLinks
          .singleWhere((l) => l.a == 'HQ-Core' && l.b == 'Access-A')
          .cable,
      'copper',
    );
  });
  test(
    'Packet Tracer zero-based names and each connection medium are retained',
    () {
      final plan = NetworkIntent.parseSimple(
        'test',
        'Connect PC0 RS232 to Router0 Console using console; '
            'Router0 Gi0/0 to Switch0 Gi0/1 using copper straight-through; '
            'Router0 Serial0/0/0 to Router1 Serial0/0/0 using serial DTE.',
      );
      expect(
        plan.nodes.map((n) => n.name),
        containsAll(['PC0', 'Router0', 'Router1', 'Switch0']),
      );
      expect(plan.links.where((l) => l.cable == 'console'), hasLength(1));
      expect(plan.links.where((l) => l.cable == 'copper'), hasLength(1));
      final serial = plan.links.singleWhere((l) => l.cable == 'serial-dte');
      expect(serial.dceEnd, 'b');
      expect(serial.exactPorts, isTrue);
      expect(plan.nodes.map((n) => n.name).toSet(), {
        'PC0',
        'Router0',
        'Router1',
        'Switch0',
      });
    },
  );
  test(
    'console link is not duplicated when the console end is written first',
    () {
      final plan = NetworkIntent.parseSimple(
        'test',
        'Connect Router0 Console to PC0 RS232 using console; '
            'Router0 Gi0/0 to Switch0 Gi0/1 using copper straight-through; '
            'Router0 Serial0/0/0 to Router1 Serial0/0/0 using serial DTE.',
      );
      expect(plan.links.where((l) => l.cable == 'console'), hasLength(1));
      expect(plan.nodes.map((n) => n.name).toSet(), {
        'PC0',
        'Router0',
        'Router1',
        'Switch0',
      });
      final console = plan.links.singleWhere((l) => l.cable == 'console');
      expect(
        {console.a.toLowerCase(), console.b.toLowerCase()},
        {'pc0', 'router0'},
      );
    },
  );
  test(
    'unknown requested cable remains visible rather than becoming copper',
    () {
      final plan = NetworkIntent.parseSimple(
        'test',
        'R1 Gi0/0 to SW1 Gi0/1 using a magic cable.',
      );
      expect(plan.links.singleWhere((l) => l.exactPorts).cable, 'magic cable');
    },
  );
  test(
    'exact missing model, modules, ports and unknown cables cannot be substituted',
    () async {
      final library = await PktTemplateLibrary.loadBundled();
      await expectLater(
        selectVariant(library, {
          'name': 'SW1',
          'type': 'switch',
          'model': 'Switch-PT-Empty',
          'exactModel': true,
        }, []),
        throwsA(isA<PktBuildFailure>()),
      );
      await expectLater(
        selectVariant(library, {
          'name': 'R1',
          'type': 'router',
          'model': '2911',
          'modules': ['imaginary-module'],
        }, []),
        throwsA(isA<PktBuildFailure>()),
      );
    },
  );
  test(
    'exact hardware and cable metadata round-trip without losing clocking',
    () {
      const intent = NetworkIntent(
        projectName: 'strict',
        nodes: [
          NetNode(
            name: 'HQ Core',
            type: 'router',
            model: '1841',
            exactModel: true,
            modules: ['HWIC-2T'],
          ),
          NetNode(
            name: 'Branch',
            type: 'router',
            model: '1841',
            exactModel: true,
            modules: ['HWIC-2T'],
          ),
        ],
        links: [
          NetLink(
            a: 'HQ Core',
            aIf: 'Serial0/0/0',
            b: 'Branch',
            bIf: 'Serial0/0/0',
            cable: 'serial-dte',
            exactPorts: true,
          ),
        ],
      );
      final restored = NetworkIntent.fromJson(intent.toJson());
      expect(restored.nodes.first.modules, ['HWIC-2T']);
      expect(restored.nodes.first.exactModel, isTrue);
      expect(restored.links.single.exactPorts, isTrue);
      expect(restored.links.single.dceEnd, 'b');
    },
  );
  test(
    'builder refuses an unknown cable and an unavailable exact port',
    () async {
      final library = await PktTemplateLibrary.loadBundled();
      for (final request in [
        ('magic cable', 'GigabitEthernet0/0'),
        ('copper', 'GigabitEthernet0/99'),
      ]) {
        await expectLater(
          buildPkt(
            plan: {
              'steps': [
                {
                  'action': 'create_nodes',
                  'nodes': [
                    {
                      'name': 'A',
                      'type': 'router',
                      'model': '2911',
                      'exactModel': true,
                    },
                    {
                      'name': 'B',
                      'type': 'router',
                      'model': '2911',
                      'exactModel': true,
                    },
                  ],
                },
                {
                  'action': 'create_links',
                  'links': [
                    {
                      'a': 'A',
                      'aIf': request.$2,
                      'b': 'B',
                      'bIf': 'GigabitEthernet0/0',
                      'cable': request.$1,
                      'exactPorts': true,
                    },
                  ],
                },
              ],
            },
            library: library,
            project: 'strict',
          ),
          throwsA(isA<PktBuildFailure>()),
        );
      }
    },
  );
  test('fiber modes and copper connectors cannot be silently mixed', () {
    const fiber = PtPort(
      'GigabitEthernet0/1',
      'eFiberGigabitEthernet',
      'gigabitethernet',
    );
    const copper = PtPort(
      'GigabitEthernet0/0',
      'eCopperGigabitEthernet',
      'gigabitethernet',
    );
    expect(catalog.cable('fiber-single')!.mismatch(fiber, fiber), isNotNull);
    expect(
      catalog
          .cable('fiber-multi')!
          .mismatch(fiber, fiber, modulesA: ['GLC-LH-SMD']),
      isNotNull,
    );
    expect(catalog.cable('fiber')!.mismatch(fiber, copper), isNotNull);
  });
  test(
    'unnamed exact hardware keeps requested modules and plain counts remain counts',
    () {
      final plan = NetworkIntent.parseSimple(
        'modules',
        'Use 2 1841 routers with HWIC-2T; 1 switch and 2 PCs.',
      );
      expect(
        plan.nodes.where((n) => n.model == '1841').map((n) => n.modules),
        everyElement(['HWIC-2T']),
      );
      expect(plan.nodes.where((n) => n.type == 'router'), hasLength(2));
      final counts = NetworkIntent.parseSimple(
        'counts',
        '1 router 1 switch 5 PCs',
      );
      expect(counts.nodes.first.name, 'R1');
      expect(counts.nodes, hasLength(7));
    },
  );
  test(
    'known connector names infer their cable without affecting explicit choices',
    () {
      final plan = NetworkIntent.parseSimple(
        'usb',
        'MCU0 USB0 to SBC0 USB0; PC0 RS232 to Router0 Console.',
      );
      expect(
        plan.links.where((l) => l.exactPorts).map((l) => l.cable),
        containsAll(['usb', 'console']),
      );
    },
  );
}
