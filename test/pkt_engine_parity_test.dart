import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/pkt/pkt_engine_builder.dart';
import 'package:net_builder/services/pkt/template_library.dart';

/// The offline engine builder, exercised over the bundled template library.
///
/// The expectations here were recorded from the sidecar's
/// `pkt_builder.py` running the SAME plan (`test/fixtures/plan_office.json`)
/// on a machine with the same library - the Dart port must agree with the
/// Python builder model for model, port for port, line for line, or a phone
/// would produce different files than a PC.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, dynamic>> planFixture() async =>
      json.decode(await File('test/fixtures/plan_office.json').readAsString())
          as Map<String, dynamic>;

  test('office plan builds the same lab the Python builder builds', () async {
    final library = await PktTemplateLibrary.loadBundled();
    final built = await buildPkt(
      plan: await planFixture(),
      library: library,
      project: 'parity',
    );

    expect(built.deviceCount, 6);
    expect(built.linkCount, 5);
    expect(built.plannedDevices, 6);
    expect(built.plannedLinks, 5);
    expect(built.version, '9.0.0.0810');

    // Model selection is the scoring port: 2811 for unhinted routers (fewer
    // ports wins the tie), IE-2000 for unhinted switches, and the exact host
    // templates for the endpoints.
    Map<String, dynamic> device(String name) => built.devices
        .firstWhere((d) => d['name'] == name, orElse: () => <String, dynamic>{});
    expect(device('R1')['model'], '2811');
    expect(device('R2')['model'], '2811');
    expect(device('SW1')['model'], 'IE-2000');
    expect(device('SW2')['model'], 'IE-2000');
    expect(device('PC1')['model'], 'PC-PT');
    expect(device('SRV1')['model'], 'Server-PT');
    expect(device('PC1')['template'], 'PC-PT+PT-HOST-NM-1CFE');
    expect(device('SRV1')['template'], 'Server-PT+PT-HOST-NM-1CFE');

    // Port resolution: the plan says GigabitEthernet, the 2811 speaks
    // FastEthernet, and the remap is reported.
    expect(
      device('R1')['ports'],
      {
        'GigabitEthernet0/0': 'FastEthernet0/0',
        'GigabitEthernet0/1': 'FastEthernet0/1',
      },
    );
    expect(
      device('SW1')['ports'],
      {
        'GigabitEthernet0/1': 'GigabitEthernet1/1',
        'FastEthernet0/1': 'FastEthernet1/1',
        'FastEthernet0/2': 'FastEthernet1/2',
      },
    );
    expect(
      device('PC1')['ports'],
      {'FastEthernet0': 'FastEthernet0'},
    );

    // Compiled configs ride along as RUNNINGCONFIG lines.
    expect(device('R1')['configLines'], 13);
    expect(device('R2')['configLines'], 12);
    expect(device('SW1')['configLines'], 5);

    // The link report names the ports the file actually cabled.
    expect(
      built.links.map((l) => '${l['a']}:${l['aIf']}<->${l['b']}:${l['bIf']}'),
      [
        'R1:FastEthernet0/0<->R2:FastEthernet0/0',
        'R1:FastEthernet0/1<->SW1:GigabitEthernet1/1',
        'R2:FastEthernet0/1<->SW2:GigabitEthernet1/1',
        'SW1:FastEthernet1/1<->PC1:FastEthernet0',
        'SW1:FastEthernet1/2<->SRV1:FastEthernet0',
      ],
    );

    // Nothing invented, nothing hidden: the warnings are exactly the
    // interpretation notes the Python builder reports.
    expect(built.warnings, [
      'R1: dropped exec-only line(s) from the saved config: end',
      'config: GigabitEthernet0/0 -> FastEthernet0/0 (slot remap)',
      'config: GigabitEthernet0/1 -> FastEthernet0/1 (slot remap)',
      'R2: dropped exec-only line(s) from the saved config: end',
      'SW1: dropped exec-only line(s) from the saved config: end',
      'SW1: GigabitEthernet0/1 -> GigabitEthernet1/1 (slot remap)',
      'SW1: FastEthernet0/1 -> FastEthernet1/1 (slot remap)',
      'SW1: FastEthernet0/2 -> FastEthernet1/2 (slot remap)',
      'SW2: dropped exec-only line(s) from the saved config: end',
      'SW2: GigabitEthernet0/1 -> GigabitEthernet1/1 (slot remap)',
    ]);

    // The app learns the drawing the build used, positions included.
    expect(built.layout['positions'], isA<Map<dynamic, dynamic>>());

    // Round-trip: the written container opens through the codec and carries
    // the configured state in the XML.
    final bytes = encryptPkt(built.xml);
    expect(isPkt(bytes), isTrue);
    // Kept for the dev-time canonical diff against the Python builder's
    // output (build/parity/office_py.pkt) - see memory/2026-10-03.md.
    try {
      final out = File('build/parity/office_dart.pkt');
      out.createSync(recursive: true);
      out.writeAsBytesSync(bytes, flush: true);
    } catch (_) {}
    final xml = utf8.decode(decryptPkt(bytes), allowMalformed: true);
    expect(xml, contains('<NAME translate="true">R1</NAME>'));
    expect(xml, contains('hostname R1'));
    expect(xml, contains('<IP>192.168.1.10</IP>')); // PC1 static IP
    expect(xml, contains('<PORT_GATEWAY>192.168.1.1</PORT_GATEWAY>'));
    expect(xml, contains('<PORT_DNS>192.168.1.50</PORT_DNS>'));
    // Server Services panels were rewritten, not inherited.
    expect(xml, contains('<POOL><NAME>LAN</NAME>'));
    expect(xml, contains('srv1.lab.local'));
    expect(xml, contains('<HTTP_SERVER><ENABLED>1</ENABLED>'));
    expect(xml, contains('<START_IP>192.168.1.100</START_IP>'));

    // Physical workspace was rebuilt to match the devices (the validator
    // inside buildPkt already enforced this; assert the visible outcome).
    expect(xml, contains('<PHYSICAL>'));
    expect(xml, isNot(contains('stale=')));
  });

  test('office plan 2: hints, serial DCE and IPv6 match the Python builder',
      () async {
    final library = await PktTemplateLibrary.loadBundled();
    final plan =
        json.decode(await File('test/fixtures/plan_office2.json').readAsString())
            as Map<String, dynamic>;
    final built = await buildPkt(plan: plan, library: library, project: 'parity2');

    expect(built.deviceCount, 5);
    expect(built.linkCount, 4);
    Map<String, dynamic> device(String name) =>
        built.devices.firstWhere((d) => d['name'] == name);
    // The hinted 2911/1941 have no serial port in this library, so the build
    // falls back to the 2811 and says why; the 2960 hint resolves exactly.
    expect(device('R1')['model'], '2811');
    expect(device('R2')['model'], '2811');
    expect(device('SW1')['model'], '2960-24TT');
    expect(
      device('R1')['ports'],
      {'Serial0/1/0': 'Serial0/2/0', 'GigabitEthernet0/0': 'FastEthernet0/0'},
    );
    expect(built.warnings, [
      'R1: used 2811 instead of 2911 (its template has no port for '
          'Serial0/1/0)',
      'R1: dropped exec-only line(s) from the saved config: end',
      'config: Serial0/1/0 -> Serial0/2/0 (slot remap)',
      'config: GigabitEthernet0/0 -> FastEthernet0/0 (slot remap)',
      'R2: used 2811 instead of 1941 (its template has no port for '
          'Serial0/1/0)',
      'R2: dropped exec-only line(s) from the saved config: end',
    ]);
    final bytes = encryptPkt(built.xml);
    try {
      final out = File('build/parity/office2_dart.pkt');
      out.createSync(recursive: true);
      out.writeAsBytesSync(bytes, flush: true);
    } catch (_) {}
    final xml = utf8.decode(decryptPkt(bytes), allowMalformed: true);
    // Serial DCE side carries the plan's clock rate.
    expect(xml, contains('<CLOCKRATE>64000</CLOCKRATE>'));
    expect(xml, contains('<CLOCKRATEFLAG>true</CLOCKRATEFLAG>'));
    // Dual-stack endpoint autoconfigures (SLAAC) rather than a static v6.
    expect(xml, contains('<IPV6_ENABLED>true</IPV6_ENABLED>'));
    expect(xml, contains('<IPV6_ADDRESS_AUTOCONFIG>true</IPV6_ADDRESS_AUTOCONFIG>'));
    // AAA panel: one user, one client, RADIUS.
    expect(xml, contains('<USER><NAME>admin</NAME>'));
    expect(xml, contains('<HOST_IP>192.168.1.1</HOST_IP>'));
    expect(xml, contains('<SERVER_TYPE>RADIUS</SERVER_TYPE>'));
    // Flat-form DHCP pool (no poolName) still built.
    expect(xml, contains('<START_IP>192.168.1.100</START_IP>'));
  });

  test('a console link is reported, not silently dropped from the file',
      () async {
    final library = await PktTemplateLibrary.loadBundled();
    final built = await buildPkt(
      plan: {
        'project': 'console',
        'steps': [
          {
            'action': 'create_nodes',
            'nodes': [
              {'name': 'R1', 'type': 'router'},
              {'name': 'PC1', 'type': 'pc'},
            ],
          },
          {
            'action': 'create_links',
            'links': [
              {
                'a': 'PC1',
                'aIf': 'Console',
                'b': 'R1',
                'bIf': 'Console',
                'cable': 'console',
              },
            ],
          },
        ],
      },
      library: library,
      project: 'console-lab',
    );

    // Both endpoints build; only the console link is skipped. Nothing is
    // silent: each device is told its 'Console' interface has no physical
    // port on any template, and the link warning says the real cause - the
    // library (extracted from real saves) has no console cable template AND
    // no device template carries a Console/RS232 port - plus the way out
    // (the engine wires it in the Packet Tracer window).
    expect(built.deviceCount, 2);
    expect(built.linkCount, 0);
    expect(built.plannedLinks, 1);
    expect(built.warnings, hasLength(3));
    expect(built.warnings[0], startsWith('R1: template '));
    expect(built.warnings[0], endsWith(' has no port for Console'));
    expect(built.warnings[1], startsWith('PC1: template '));
    expect(built.warnings[1], endsWith(' has no port for Console'));
    expect(
      built.warnings[2],
      startsWith('link PC1-R1: no console cable template in the library'),
    );
    expect(built.warnings[2], contains('Console/RS232'));
    expect(built.warnings[2], contains('Packet Tracer'));
  });

  test('plan without devices raises, exactly like the Python builder',
      () async {
    final library = await PktTemplateLibrary.loadBundled();
    await expectLater(
      buildPkt(
        plan: {
          'project': 'empty',
          'steps': [
            {
              'action': 'create_nodes',
              'nodes': <dynamic>[],
            },
          ],
        },
        library: library,
      ),
      throwsA(isA<PktBuildFailure>()),
    );
  });

  test('unknown device kinds are reported, other devices still built',
      () async {
    final library = await PktTemplateLibrary.loadBundled();
    final built = await buildPkt(
      plan: {
        'project': 'mixed',
        'steps': [
          {
            'action': 'create_nodes',
            'nodes': [
              {'name': 'R1', 'type': 'router'},
              {'name': 'HAL', 'type': 'quantum-computer'},
            ],
          },
        ],
      },
      library: library,
    );
    expect(built.deviceCount, 1);
    expect(
      built.warnings.any((w) => w.contains('HAL') && w.contains('no ')),
      isTrue,
    );
  });
}
