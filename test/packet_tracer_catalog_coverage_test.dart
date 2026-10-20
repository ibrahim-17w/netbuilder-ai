import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/packet_tracer/catalog.dart';
import 'package:net_builder/services/pkt/template_library.dart';
import 'package:net_builder/services/pkt/pkt_engine_builder.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = PacketTracerCatalog.instance;
  test('every catalog model is recognized as that exact model', () {
    for (final device in catalog.devices) {
      final plan = NetworkIntent.parseSimple('catalog', '1 ${device.model}');
      expect(
        plan.nodes.where((n) => n.model == device.model && n.exactModel),
        hasLength(1),
        reason: device.model,
      );
    }
  });
  test('compatibility separates recognition, local builds, and live proof', () {
    final known = catalog.compatibility('2911', installedVersion: '9.1.0.1234');
    final unknown = catalog.compatibility(
      'Uncatalogued-Model',
      installedVersion: '9.0.0.0810',
    );

    expect(known.recognized, isTrue);
    expect(known.buildable, isTrue);
    expect(known.liveVerificationRecorded, isFalse);
    expect(known.versionNeedsReview, isTrue);
    expect(known.versionNote, contains('Compatibility needs a live check'));
    expect(unknown.recognized, isFalse);
    expect(unknown.buildable, isFalse);
  });
  test(
    'every available model compiles and every available cable retains its medium',
    () async {
      final library = await PktTemplateLibrary.loadBundled();
      final output = Directory('build/hardware-qa')
        ..createSync(recursive: true);
      final modelResults = <Map<String, dynamic>>[];
      for (final device in catalog.devices) {
        if (!device.placeable) {
          modelResults.add({
            'model': device.model,
            'recognized': true,
            'serialized': false,
            'liveVerified': false,
          });
          continue;
        }
        final built = await buildPkt(
          plan: {
            'steps': [
              {
                'action': 'create_nodes',
                'nodes': [
                  {
                    'name': 'Device0',
                    'type': device.type,
                    'model': device.model,
                    'exactModel': true,
                  },
                ],
              },
            ],
          },
          library: library,
          project: 'catalog-${device.model}',
        );
        final xml = XmlDocument.parse(built.xml);
        final type = xml
            .findAllElements('DEVICE')
            .single
            .getElement('ENGINE')!
            .getElement('TYPE')!;
        expect(type.getAttribute('model'), device.model);
        expect(built.deviceCount, 1, reason: device.model);
        modelResults.add({
          'model': device.model,
          'recognized': true,
          'serialized': true,
          'liveVerified': false,
        });
      }
      final cableResults = <Map<String, dynamic>>[];
      for (final cable in catalog.cables.where((c) => c.id != 'fiber')) {
        if (!cable.templateAvailable) {
          cableResults.add({
            'cable': cable.id,
            'recognized': true,
            'serialized': false,
            'liveVerified': false,
          });
          continue;
        }
        ({PtDevice device, PtHardwareVariant variant, PtPort port})? first,
            second;
        final candidates = [
          for (final d in catalog.devices)
            for (final v in d.variants)
              for (final p in v.ports)
                if (cable.accepts(p)) (device: d, variant: v, port: p),
        ];
        for (final a in candidates) {
          for (final b in candidates) {
            if (cable.mismatch(
                  a.port,
                  b.port,
                  modulesA: a.variant.modules,
                  modulesB: b.variant.modules,
                ) ==
                null) {
              first = a;
              second = b;
              break;
            }
          }
          if (first != null) break;
        }
        expect(
          first,
          isNotNull,
          reason: '${cable.id}: no proven compatible endpoint pair',
        );
        final a = first!, b = second!;
        final built = await buildPkt(
          plan: {
            'steps': [
              {
                'action': 'create_nodes',
                'nodes': [
                  {
                    'name': 'A',
                    'type': a.device.type,
                    'model': a.device.model,
                    'modules': a.variant.modules,
                    'exactModel': true,
                  },
                  {
                    'name': 'B',
                    'type': b.device.type,
                    'model': b.device.model,
                    'modules': b.variant.modules,
                    'exactModel': true,
                  },
                ],
              },
              {
                'action': 'create_links',
                'links': [
                  {
                    'a': 'A',
                    'aIf': a.port.name,
                    'b': 'B',
                    'bIf': b.port.name,
                    'cable': cable.id,
                    'exactPorts': true,
                    'dce': cable.id == 'serial-dte' ? 'b' : 'a',
                  },
                ],
              },
              if (cable.id.startsWith('serial'))
                {
                  'action': 'paste_cli',
                  'configs': {
                    cable.id == 'serial-dte' ? 'B' : 'A':
                        'interface ${cable.id == 'serial-dte' ? b.port.name : a.port.name}\nclock rate 64000\nexit',
                  },
                },
            ],
          },
          library: library,
          project: 'cable-${cable.id}',
        );
        expect(built.linkCount, 1, reason: cable.id);
        final bytes = encryptPkt(built.xml);
        File('${output.path}/${cable.id}.pkt').writeAsBytesSync(bytes);
        final xml = XmlDocument.parse(utf8.decode(decryptPkt(bytes)));
        final link = xml.findAllElements('LINK').single;
        expect(link.getElement('TYPE')!.innerText, cable.medium);
        if (cable.variant.isNotEmpty) {
          expect(
            link.getElement('CABLE')!.getElement('TYPE')!.innerText,
            cable.variant,
          );
        }
        expect(built.links.single['aIf'], a.port.name);
        expect(built.links.single['bIf'], b.port.name);
        cableResults.add({
          'cable': cable.id,
          'recognized': true,
          'serialized': true,
          'liveVerified': false,
        });
      }
      File('${output.path}/coverage.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'version': catalog.version,
          'models': modelResults,
          'cables': cableResults,
          'verification':
              'Generated and decoded locally; native Packet Tracer simulation not verified.',
        }),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
