// The AP floated: a plan that cabled SW1 to an AP produced a .pkt with the
// access point placed in the workspace and cabled to nothing.
//
// `AccessPoint-PT-A`'s Ethernet port carries no <NAME> in any Packet Tracer
// save - the port is named from the host module and never written out - so the
// manifest recorded it empty and no interface on the AP could ever be resolved.
// 34 models were in that state: every AccessPoint, the IpPhone, the Hub and
// the whole IoT/MCU family. The sidecar's generator had to fall back to its
// spare-port remap to cable anything at all, which is luck rather than design.
//
// The BUILD, the naming and the sidecar's own cabling tests are pinned on the
// Python side (sidecar/test_pkt_ap_cabling.py), where the full template
// library lives. What this file pins is the two Dart halves: the view the
// builder names ports through, and the lexicon that says what to cable.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/nlu/lexicon.dart';
import 'package:net_builder/services/pkt/template_library.dart';

void main() {
  // The library is read from the asset bundle, which needs the binding up
  // before rootBundle answers.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a chosen model names every port a cable can use', () {
    test('no cableable port is left unnamed', () async {
      final library = await PktTemplateLibrary.loadBundled();
      final unnamed = <String>[];
      for (final device in library.devices) {
        for (final port in device.withNamedPorts().ports) {
          if (port.family.isNotEmpty && port.name.isEmpty) {
            unnamed.add('${device.model}: index ${port.index} ${port.family}');
          }
        }
      }
      expect(
        unnamed,
        isEmpty,
        reason: 'an unnamed cableable port can never be cabled - that device '
            'would be placed floating in the workspace',
      );
    });

    test('an access point declares its Ethernet port', () async {
      final library = await PktTemplateLibrary.loadBundled();
      final aps = library.devices
          .where(
            (d) =>
                d.kind.toLowerCase().contains('accesspoint') ||
                d.model.toLowerCase().contains('accesspoint'),
          )
          .toList();
      expect(aps, isNotEmpty, reason: 'the library has access point models');
      for (final ap in aps) {
        final wired = ap
            .withNamedPorts()
            .ports
            .where((p) => p.family.isNotEmpty && p.family != 'wireless')
            .toList();
        expect(
          wired,
          isNotEmpty,
          reason: '${ap.model} has no nameable Ethernet port at all',
        );
        for (final p in wired) {
          expect(p.name, isNotEmpty, reason: '${ap.model} port ${p.index}');
        }
      }
    });

    test('every named port is unique inside its device', () async {
      final library = await PktTemplateLibrary.loadBundled();
      for (final device in library.devices) {
        final names = device
            .withNamedPorts()
            .ports
            .where((p) => p.name.isNotEmpty)
            .map((p) => p.name)
            .toList();
        expect(
          names.toSet().length,
          names.length,
          reason: '${device.model} carries the same port name twice, so a '
              'cable could be attached to either',
        );
      }
    });

    test('naming is stable: the same model yields the same names', () async {
      final library = await PktTemplateLibrary.loadBundled();
      for (final device in library.devices.take(25)) {
        final once = device.withNamedPorts().ports.map((p) => p.name).toList();
        final twice = device.withNamedPorts().ports.map((p) => p.name).toList();
        expect(twice, once, reason: '${device.model} named its ports two ways');
      }
    });
  });

  group('the lexicon asks for ports that exist', () {
    test('the wireless kind names a port the library carries', () async {
      final library = await PktTemplateLibrary.loadBundled();
      final kind = deviceKinds.firstWhere((k) => k.type == 'wireless');
      final models = <String>{
        for (final d in library.devices)
          if (apModels.contains(d.model))
            for (final p in d.withNamedPorts().ports) p.name,
      };
      expect(
        models,
        contains(kind.port),
        reason: 'the wireless kind asks for "${kind.port}", which no port in '
            'the library carries - the cable then needs the spare-port remap '
            'to survive at all',
      );
    });

    test('the phone kind names a port the library carries', () async {
      final library = await PktTemplateLibrary.loadBundled();
      final kind = deviceKinds.firstWhere((k) => k.type == 'phone');
      final models = <String>{
        for (final d in library.devices)
          if (phoneModels.contains(d.model))
            for (final p in d.withNamedPorts().ports) p.name,
      };
      expect(models, contains(kind.port));
    });
  });
}

const apModels = {'AccessPoint-PT', 'AccessPoint-PT-A', 'AccessPoint-PT-N'};
const phoneModels = {'7960', '7961', '7962'};
